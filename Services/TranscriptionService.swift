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
            case .appleSpeech: return "Apple Speech (System On-Device)"
            case .whisperKit: return "Whisper (WhisperKit Neural Engine)"
            }
        }
    }

    var backend: Backend = .appleSpeech

    typealias TranscriptHandler = (_ text: String, _ start: TimeInterval?, _ end: TimeInterval?) -> Void

    func startStreaming(handler: @escaping TranscriptHandler) async throws {
        switch backend {
        case .appleSpeech:
            try await AppleSpeechBackend.shared.requestAuthorization()
            try AppleSpeechBackend.shared.start(handler: handler)
        case .whisperKit:
            try await WhisperBackend.shared.start(handler: handler)
        }
    }

    func transcribe(audioURL: URL) async throws -> [TranscriptSegment] {
        switch backend {
        case .appleSpeech:
            return try await AppleSpeechBackend.shared.transcribe(audioURL: audioURL)
        case .whisperKit:
            return try await WhisperBackend.shared.transcribe(audioURL: audioURL)
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
