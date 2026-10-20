//
//  LanguageModelResponder.swift
//  NotifyAIServices
//

import Foundation
import FoundationModels

/// Sends one structured request to a language model.
protocol LanguageModelResponder: Sendable {
    func respond<Content: Generable>(generating type: Content.Type, instructions: String, prompt: String) async throws -> Content

    /// Fills one list of short points per heading. The output schema has exactly these
    /// headings, so the model can neither rename nor skip one.
    /// - Returns: The points per heading, in the order of `headings`.
    func respondSections(headings: [String], instructions: String, prompt: String) async throws -> [[String]]
}

extension LanguageModelResponder {
    /// Responders that only answer typed requests (test doubles) have no sections.
    func respondSections(headings: [String], instructions: String, prompt: String) async throws -> [[String]] {
        throw SummarizationError.sectionsUnsupported
    }
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

    func respondSections(headings: [String], instructions: String, prompt: String) async throws -> [[String]] {
        let points = DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self), maximumElements: 6)
        // Property names stay simple identifiers; the heading itself is the description.
        let properties = headings.enumerated().map { index, heading in
            DynamicGenerationSchema.Property(name: "section\(index + 1)", description: heading, schema: points)
        }
        let root = DynamicGenerationSchema(name: "TemplateSections", description: "Points under the user's headings", properties: properties)
        let schema = try GenerationSchema(root: root, dependencies: [])
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 1_000)
        let content = try await session.respond(to: prompt, schema: schema, options: options).content
        return try headings.indices.map { index in
            try content.value([String].self, forProperty: "section\(index + 1)")
        }
    }
}

enum SummarizationError: LocalizedError {
    case emptyInput
    case sectionsUnsupported

    var errorDescription: String? {
        switch self {
        case .emptyInput: "Es gibt keinen Text, der zusammengefasst werden kann."
        case .sectionsUnsupported: "Eigene Abschnitte werden von diesem Sprachmodell nicht unterstützt."
        }
    }
}
