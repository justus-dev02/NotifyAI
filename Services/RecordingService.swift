//
//  RecordingService.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//  Updated for Resampled Audio Conversion (16kHz), Interruption Handling & Thread-Safe CoreAudio Engine.
//

import AVFoundation
import Accelerate

final class RecordingService: NSObject {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var isPausedState = false
    private var startTS: Date?
    private var accumulatedDuration: TimeInterval = 0
    private var pauseTS: Date?
    private let audioSessionService: AudioSessionService

    private(set) var isRecording = false

    /// Callback for live 16kHz mono audio buffers (consumed by WhisperKit and Apple Speech)
    var bufferConsumer: ((AVAudioPCMBuffer) -> Void)?
    /// Callback for RMS volume visualization (0.0 ... 1.0)
    var amplitudeCallback: ((Float) -> Void)?
    /// Callback when recording is interrupted by the system (e.g., incoming call)
    var onInterrupted: ((Bool) -> Void)?

    init(audioSessionService: AudioSessionService = AudioSessionService()) {
        self.audioSessionService = audioSessionService
        super.init()
        setupInterruptionHandling()
    }

    var recordedDuration: TimeInterval {
        guard let start = startTS else { return accumulatedDuration }
        if isPausedState {
            return accumulatedDuration
        }
        return accumulatedDuration + Date().timeIntervalSince(start)
    }

    func start(to url: URL) throws {
        // 1. Configure and activate audio session
        try audioSessionService.configureForRecording()

        startTS = Date()
        accumulatedDuration = 0
        isRecording = true
        isPausedState = false

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        // Safety check for valid sample rate
        let sampleRate = inputFormat.sampleRate > 0 ? inputFormat.sampleRate : 44100.0
        let channels = inputFormat.channelCount > 0 ? inputFormat.channelCount : 1
        let hardwareRecordingFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) ?? inputFormat

        // Target standard: 16kHz Mono Float/PCM for high quality STT & storage efficiency
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000.0, channels: 1, interleaved: false) else {
            throw NSError(domain: "RecordingService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Konnte Ziel-Audioformat (16kHz) nicht erstellen."])
        }

        // Setup format converter
        converter = AVAudioConverter(from: hardwareRecordingFormat, to: targetFormat)

        // Target file: 16kHz 16-bit Int16 PCM CAF/WAV
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        // Clean up previous file at destination if present
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        file = try AVAudioFile(forWriting: url, settings: fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: hardwareRecordingFormat) { [weak self] buffer, _ in
            guard let self = self, !self.isPausedState else { return }

            // 1. Calculate RMS amplitude for UI visualization
            self.calculateAndPublishAmplitude(from: buffer)

            // 2. Convert to 16kHz mono buffer
            guard let converter = self.converter else { return }
            let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * (16000.0 / buffer.format.sampleRate) + 256)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }

            var error: NSError?
            var hasProvidedBuffer = false
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                if !hasProvidedBuffer {
                    hasProvidedBuffer = true
                    outStatus.pointee = .haveData
                    return buffer
                } else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
            }

            converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

            if error == nil && convertedBuffer.frameLength > 0 {
                // 3. Write converted 16kHz buffer to disk
                do {
                    try self.file?.write(from: convertedBuffer)
                } catch {
                    print("RecordingService file write error: \(error)")
                }

                // 4. Forward resampled buffer to active STT engine
                self.bufferConsumer?(convertedBuffer)
            }
        }

        engine.prepare()
        try engine.start()
    }

    func pause() {
        guard isRecording, !isPausedState else { return }
        isPausedState = true
        if let start = startTS {
            accumulatedDuration += Date().timeIntervalSince(start)
            startTS = nil
        }
    }

    func resume() {
        guard isRecording, isPausedState else { return }
        isPausedState = false
        startTS = Date()
    }

    func stop() -> TimeInterval {
        guard isRecording else { return accumulatedDuration }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil // Flushes headers & finalizes CAF/WAV container
        converter = nil
        isRecording = false
        isPausedState = false

        if let start = startTS {
            accumulatedDuration += Date().timeIntervalSince(start)
            startTS = nil
        }

        audioSessionService.deactivate()
        return accumulatedDuration
    }

    private func calculateAndPublishAmplitude(from buffer: AVAudioPCMBuffer) {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        var rms: Float = 0
        if let floatData = buffer.floatChannelData?[0] {
            vDSP_rmsqv(floatData, 1, &rms, vDSP_Length(frameLength))
        }

        if rms > 0 {
            DispatchQueue.main.async { [weak self] in
                self?.amplitudeCallback?(rms)
            }
        }
    }

    private func setupInterruptionHandling() {
        audioSessionService.onInterruption = { [weak self] type in
            guard let self = self, self.isRecording else { return }
            switch type {
            case .began:
                self.pause()
                self.onInterrupted?(true)
            case .ended:
                self.resume()
                self.onInterrupted?(false)
            @unknown default:
                break
            }
        }

        audioSessionService.onRouteChange = { [weak self] reason in
            guard let self = self, self.isRecording else { return }
            if reason == .oldDeviceUnavailable {
                // E.g. AirPods were disconnected, pause safely
                self.pause()
                self.onInterrupted?(true)
            }
        }
    }
}
