//
//  RecordungService.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import AVFoundation

final class RecordingService: NSObject {
    private let engine = AVAudioEngine()
    private let fileFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    private var file: AVAudioFile?
    private var isPaused = false
    private var startTS: Date?
    private(set) var recordedDuration: TimeInterval = 0

    // Optional consumer to forward live audio buffers (for STT backends)
    var bufferConsumer: ((AVAudioPCMBuffer) -> Void)?
    var amplitudeCallback: ((Float) -> Void)?

    func start(to url: URL) throws {
        // 1. Activate session FIRST to ensure hardware format is known
        try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: [.allowBluetooth, .duckOthers])
        try AVAudioSession.sharedInstance().setActive(true)
        
        startTS = Date()
        let input = engine.inputNode
        var format = input.outputFormat(forBus: 0)
        
        // 2. Safety check: If the format is invalid (common in Simulator), use a standard fallback
        if format.sampleRate <= 0 {
            format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        }
        
        // 3. Create the file with the determined format
        file = try AVAudioFile(forWriting: url, settings: format.settings)
        
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, !self.isPaused else { return }
            
            // Calculate RMS for amplitude visualization
            var rms: Float = 0
            let frameLength = Int(buffer.frameLength)
            if let floatData = buffer.floatChannelData?[0] {
                var sum: Float = 0
                for i in 0..<frameLength {
                    let sample = floatData[i]
                    sum += sample * sample
                }
                rms = sqrt(sum / Float(max(1, frameLength)))
            } else if let int16Data = buffer.int16ChannelData?[0] {
                var sum: Float = 0
                for i in 0..<frameLength {
                    let sample = Float(int16Data[i]) / 32768.0
                    sum += sample * sample
                }
                rms = sqrt(sum / Float(max(1, frameLength)))
            }

            if rms > 0 {
                DispatchQueue.main.async {
                    self.amplitudeCallback?(rms)
                }
            }

            do { 
                try self.file?.write(from: buffer)
                // Forward buffer to any live transcription backend
                self.bufferConsumer?(buffer)
            } catch { print("write error", error) }
        }
        
        try engine.start()
    }

    func pause() { isPaused = true }
    func resume() { isPaused = false }

    func stop() -> TimeInterval {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil // Finalize & flush audio file headers to disk
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if let start = startTS { recordedDuration = Date().timeIntervalSince(start) }
        return recordedDuration
    }
}

