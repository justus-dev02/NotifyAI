//
//  TranscriptionService.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import Foundation
import Speech

final class TranscriptionService {
    enum Backend: String, CaseIterable, Identifiable {
        case whisperKit
        case appleSpeech

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .appleSpeech: return "Apple Speech"
            case .whisperKit: return "WhisperKit"
            }
        }
    }

    var backend: Backend = .appleSpeech  // <- standardmäßig Apple

    typealias TranscriptHandler = (_ text: String, _ start: TimeInterval?, _ end: TimeInterval?) -> Void

    func startStreaming(handler: @escaping TranscriptHandler) async throws {
        switch backend {
        case .appleSpeech:
            try await AppleSpeechBackend.shared.requestAuthorization()
            try await AppleSpeechBackend.shared.start(handler: handler)
        case .whisperKit:
            try await WhisperBackend.shared.start(handler: handler)
        }
    }

    func stop() {
        switch backend {
        case .appleSpeech:
            AppleSpeechBackend.shared.stop()
        case .whisperKit:
            WhisperBackend.shared.stop()
        }
    }
}

