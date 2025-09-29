//
//  WhisperBackend.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//
/*
import Foundation
import AVFoundation
import WhisperKit   // SPM

final class WhisperBackend {
    static let shared = WhisperBackend()
    private var pipeline: WhisperKit?
    private var task: Task<Void, Never>?

    func start(format: AVAudioFormat, handler: @escaping TranscriptionService.TranscriptHandler) async throws {
        // Model-Ladung: z.B. "base" DE/EN – in der App mitliefern oder per Onboarding laden
        if pipeline == nil {
            pipeline = try await WhisperKit(model: .base) // oder .small / quantisierte Variante
        }
        // Microphone streamen
        task = Task {
            for await result in pipeline!.streamMicrophone() {
                // result.text, result.t0/result.t1 enthalten Text und Wort-Timestamps (abhängig vom Modell/Config)
                handler(result.text, result.t0, result.t1)
            }
        }
    }

    func stop() {
        task?.cancel()
        pipeline?.stopStreamingMicrophone()
    }
}
*/
