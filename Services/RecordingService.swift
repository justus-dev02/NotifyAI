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

    func start(to url: URL) throws {
        startTS = Date()
        file = try AVAudioFile(forWriting: url, settings: fileFormat.settings)
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            guard let self, !self.isPaused else { return }
            do { 
                try self.file?.write(from: buffer)
                // Forward buffer to any live transcription backend
                self.bufferConsumer?(buffer)
            } catch { print("write error", error) }
        }
        try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: [.allowBluetooth, .duckOthers])
        try AVAudioSession.sharedInstance().setActive(true)
        try engine.start()
    }

    func pause() { isPaused = true }
    func resume() { isPaused = false }

    func stop() -> TimeInterval {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        if let start = startTS { recordedDuration = Date().timeIntervalSince(start) }
        return recordedDuration
    }
}

