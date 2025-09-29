//
//  RecordungService.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import AVFoundation

final class RecordingService: NSObject {
    private let engine = AVAudioEngine()
    private var format: AVAudioFormat!
    var inputNode: AVAudioInputNode? { engine.inputNode }

    func start(tap: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        format = inputNode?.outputFormat(forBus: 0)
        inputNode?.installTap(onBus: 0, bufferSize: 2048, format: format, block: tap)
        try engine.start()
    }

    func stop() {
        inputNode?.removeTap(onBus: 0)
        engine.stop()
    }
}
