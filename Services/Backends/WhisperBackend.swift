//
//  WhisperBackend.swift
//  NotifyAI
//
//  Created by OpenAI Assistant on 05.10.23.
//

import Foundation
import AVFoundation

#if canImport(WhisperKit)
import WhisperKit
#endif

final class WhisperBackend {
    static let shared = WhisperBackend()

    private init() {}

    #if canImport(WhisperKit)
    private var pipeline: WhisperKit?
    private var streamTask: Task<Void, Never>?
    #endif

    func start(handler: @escaping TranscriptionService.TranscriptHandler) async throws {
        #if canImport(WhisperKit)
        if pipeline == nil {
            pipeline = try await WhisperKit(model: .small)
        }

        guard let pipeline else { return }

        try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: [.allowBluetooth, .allowBluetoothA2DP, .duckOthers])
        try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)

        streamTask?.cancel()
        streamTask = Task { [weak pipeline] in
            guard let pipeline else { return }
            for await result in pipeline.streamMicrophone() {
                handler(result.text, result.t0, result.t1)
            }
        }
        #else
        throw NSError(domain: "WhisperBackend", code: -1, userInfo: [NSLocalizedDescriptionKey: "WhisperKit framework not available"])
        #endif
    }

    func stop() {
        #if canImport(WhisperKit)
        streamTask?.cancel()
        streamTask = nil
        pipeline?.stopStreamingMicrophone()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
