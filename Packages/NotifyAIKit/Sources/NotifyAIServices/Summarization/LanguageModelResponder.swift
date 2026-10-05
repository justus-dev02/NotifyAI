//
//  LanguageModelResponder.swift
//  NotifyAIServices
//

import Foundation
import FoundationModels

/// Sends one structured request to a language model.
protocol LanguageModelResponder: Sendable {
    func respond<Content: Generable>(generating type: Content.Type, instructions: String, prompt: String) async throws -> Content
}

/// Apple's on-device model.
struct SystemLanguageModelResponder: LanguageModelResponder {
    func respond<Content: Generable>(generating type: Content.Type, instructions: String, prompt: String) async throws -> Content {
        // A fresh session per request: the transcript must not accumulate in the context.
        let session = LanguageModelSession(instructions: instructions)
        // Low temperature: summaries should reproduce the content, not vary it.
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 1_000)
        let response = try await session.respond(to: prompt, generating: type, options: options)
        return response.content
    }
}

enum SummarizationError: LocalizedError {
    case emptyInput

    var errorDescription: String? {
        switch self {
        case .emptyInput: "Es gibt keinen Text, der zusammengefasst werden kann."
        }
    }
}
