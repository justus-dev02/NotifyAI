//
//  AudioRecorder.swift
//  NotifyAI
//

import Accelerate
import AVFoundation
import OSLog
import Synchronization

/// A microphone level reading for the UI.
struct AudioLevel: Sendable {
    /// Root mean square of the last buffer, 0…1.
    let rms: Float
    /// Recorded time so far (pauses excluded).
    let recordedTime: TimeInterval
}

/// The two streams a running recording produces.
struct AudioCaptureStreams: Sendable {
    /// Every converted buffer, in order and without gaps. Unbounded so transcription never loses audio.
    let chunks: AsyncStream<AudioChunk>
    /// Level updates for metering. Only the newest value is kept.
    let levels: AsyncStream<AudioLevel>
}

enum AudioRecorderError: LocalizedError {
    case alreadyRecording
    case noInputDevice
    case converterUnavailable
    case engineStartFailed(any Error)
    case fileCreationFailed(any Error)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            "Es läuft bereits eine Aufnahme."
        case .noInputDevice:
            "Es wurde kein Mikrofon gefunden."
        case .converterUnavailable:
            "Das Audioformat des Mikrofons wird nicht unterstützt."
        case .engineStartFailed(let error):
            "Die Aufnahme konnte nicht gestartet werden: \(error.localizedDescription)"
        case .fileCreationFailed(let error):
            "Die Audiodatei konnte nicht angelegt werden: \(error.localizedDescription)"
        }
    }
}

/// Captures microphone audio, converts it to 16 kHz mono, writes it to disk and
/// streams it to live transcription.
///
/// Threading: the public API is main-actor isolated. The tap block runs on an audio
/// thread and only touches shared state through `CaptureContext`, which is protected
/// by a mutex. Time is measured in written samples, so it excludes pauses and matches
/// the audio file exactly.
@MainActor
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let capture = CaptureContext()
    private let logger = Logger.audio
    private var configurationObserver: (any NSObjectProtocol)?

    private(set) var isRunning = false

    /// Recorded time so far, excluding pauses.
    var recordedTime: TimeInterval { capture.recordedTime }

    var isPaused: Bool { capture.isPaused }

    func start(writingTo url: URL) throws -> AudioCaptureStreams {
        guard !isRunning else { throw AudioRecorderError.alreadyRecording }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: AudioFormat.recordingFileSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw AudioRecorderError.fileCreationFailed(error)
        }

        let (chunks, chunkContinuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
        let (levels, levelContinuation) = AsyncStream.makeStream(of: AudioLevel.self, bufferingPolicy: .bufferingNewest(1))
        capture.begin(file: file, chunks: chunkContinuation, levels: levelContinuation)

        do {
            try installInputTap()
            engine.prepare()
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            capture.finish()
            throw (error as? AudioRecorderError) ?? AudioRecorderError.engineStartFailed(error)
        }

        isRunning = true
        observeConfigurationChanges()
        logger.info("Recording started")
        return AudioCaptureStreams(chunks: chunks, levels: levels)
    }

    /// Stops writing audio. The engine keeps running so the level meter stays live.
    func pause() {
        capture.setPaused(true)
    }

    /// Resumes writing. Restarts the engine if the system stopped it (e.g. after a phone call).
    func resume() throws {
        capture.setPaused(false)
        if isRunning, !engine.isRunning {
            do {
                try engine.start()
            } catch {
                capture.setPaused(true)
                throw AudioRecorderError.engineStartFailed(error)
            }
        }
    }

    /// Stops the recording, finalizes the file and finishes both streams.
    /// - Returns: The recorded duration in seconds.
    @discardableResult
    func stop() -> TimeInterval {
        guard isRunning else { return capture.recordedTime }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        isRunning = false
        let duration = capture.finish()
        logger.info("Recording stopped after \(duration, format: .fixed(precision: 1)) s")
        return duration
    }

    // MARK: - Private

    private func installInputTap() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }
        let outputFormat = AudioFormat.makeProcessingFormat()
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioRecorderError.converterUnavailable
        }
        // Mix all input channels instead of silently using only the first one.
        converter.downmix = true
        capture.setConverter(converter, outputFormat: outputFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: Self.makeTapBlock(for: capture))
    }

    /// Built in a nonisolated context: a closure created inside a main-actor method would
    /// inherit main-actor isolation and trap when Core Audio calls it on its own thread.
    private nonisolated static func makeTapBlock(for capture: CaptureContext) -> AVAudioNodeTapBlock {
        { buffer, _ in capture.process(buffer) }
    }

    /// The input device or its format changed (headset plugged in, other microphone
    /// selected on the Mac). The engine has stopped; rebuild the tap for the new format.
    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleConfigurationChange()
            }
        }
    }

    private func handleConfigurationChange() {
        guard isRunning else { return }
        logger.info("Audio configuration changed, rebuilding input tap")
        do {
            try installInputTap()
            if !capture.isPaused {
                try engine.start()
            }
        } catch {
            logger.error("Restarting after a configuration change failed: \(error.localizedDescription, privacy: .public)")
            capture.setPaused(true)
        }
    }
}

// MARK: - Capture context

/// State shared between the main actor and the audio thread.
private final class CaptureContext: Sendable {
    private struct State {
        var file: AVAudioFile?
        var converter: AVAudioConverter?
        var outputFormat: AVAudioFormat?
        var isPaused = false
        var framesWritten: Int64 = 0
        var hasLoggedWriteError = false
        var chunks: AsyncStream<AudioChunk>.Continuation?
        var levels: AsyncStream<AudioLevel>.Continuation?
    }

    private let state = Mutex(State())

    var recordedTime: TimeInterval {
        state.withLock { Double($0.framesWritten) / AudioFormat.sampleRate }
    }

    var isPaused: Bool {
        state.withLock { $0.isPaused }
    }

    func begin(
        file: AVAudioFile,
        chunks: AsyncStream<AudioChunk>.Continuation,
        levels: AsyncStream<AudioLevel>.Continuation
    ) {
        state.withLock { state in
            state = State()
            state.file = file
            state.chunks = chunks
            state.levels = levels
        }
    }

    func setConverter(_ converter: AVAudioConverter, outputFormat: AVAudioFormat) {
        state.withLock { state in
            state.converter = converter
            state.outputFormat = outputFormat
        }
    }

    func setPaused(_ paused: Bool) {
        state.withLock { $0.isPaused = paused }
    }

    /// Closes the file (which finalizes it) and finishes the streams.
    @discardableResult
    func finish() -> TimeInterval {
        state.withLock { state in
            state.file = nil
            state.converter = nil
            state.chunks?.finish()
            state.levels?.finish()
            state.chunks = nil
            state.levels = nil
            return Double(state.framesWritten) / AudioFormat.sampleRate
        }
    }

    /// Called on the audio thread for every captured buffer.
    func process(_ input: AVAudioPCMBuffer) {
        state.withLock { state in
            guard let converter = state.converter, let outputFormat = state.outputFormat else { return }

            let ratio = outputFormat.sampleRate / input.format.sampleRate
            let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

            // The converter keeps its resampling state between calls, so it must see every
            // buffer (also while paused) to avoid clicks when writing resumes.
            var didProvideInput = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if didProvideInput {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                didProvideInput = true
                inputStatus.pointee = .haveData
                return input
            }
            guard status != .error, output.frameLength > 0 else { return }

            let samples = output.monoSamples
            let rms = Self.rms(of: samples)

            if !state.isPaused {
                do {
                    try state.file?.write(from: output)
                } catch {
                    // Log once; a full disk would otherwise flood the log ten times per second.
                    if !state.hasLoggedWriteError {
                        state.hasLoggedWriteError = true
                        Logger.audio.error("Writing audio failed: \(error.localizedDescription, privacy: .public)")
                    }
                }

                state.chunks?.yield(AudioChunk(samples: samples, startFrame: state.framesWritten))
                state.framesWritten += Int64(samples.count)
            }

            let recordedTime = Double(state.framesWritten) / AudioFormat.sampleRate
            state.levels?.yield(AudioLevel(rms: state.isPaused ? 0 : rms, recordedTime: recordedTime))
        }
    }

    private static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return vDSP.rootMeanSquare(samples)
    }
}
