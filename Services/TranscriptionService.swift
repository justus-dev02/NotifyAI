//
//  TranscriptionService.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import Foundation

final class TranscriptionService {
    enum Backend { case whisperKit, appleSpeech }
    var backend: Backend = .appleSpeech  // <- standardmäßig Apple

    typealias TranscriptHandler = (_ text: String, _ start: TimeInterval?, _ end: TimeInterval?) -> Void

    func startStreaming(handler: @escaping TranscriptHandler) async throws {
        switch backend {
        case .appleSpeech:
            try await AppleSpeechBackend.shared.requestAuthorization()
            try AppleSpeechBackend.shared.start(handler: handler)
        case .whisperKit:
            // ... wie zuvor (weggelassen)
            throw NSError(domain: "NotImplemented", code: -1)
        }
    }

    func stop() {
        switch backend {
        case .appleSpeech: AppleSpeechBackend.shared.stop()
        case .whisperKit:  /* WhisperBackend.shared.stop() */ break
        }
    }
}

