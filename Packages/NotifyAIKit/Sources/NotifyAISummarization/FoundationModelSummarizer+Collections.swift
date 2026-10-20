//
//  FoundationModelSummarizer+Collections.swift
//  NotifyAISummarization
//

import Foundation
import NotifyAICore
import NotifyAISupport

/// Summaries across several notes, made from the notes' own summaries.
extension FoundationModelSummarizer {
    /// Condenses the notes' summaries step by step until they fit into one request, as for the
    /// chapters of a long recording, and writes one summary across all of them.
    package func summarizeCollection(
        _ sources: [CollectionSource],
        request: SummaryRequest,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> NoteSummary {
        let chunker = TextChunker(budget: Self.inputTokenBudget, measure: tokenMeasure)
        let texts = sources.enumerated().map { index, source in
            source.promptText(number: index + 1, count: sources.count)
        }
        let notes = try await reduce(texts, request: request, fitting: chunker)
        progress(0.6)
        let prompt = "Summaries of \(sources.count) notes, oldest first:\n\n\(notes.text)"
        let generated = try await respond(
            generating: GeneratedSummary.self,
            instructions: Self.instructions(for: request, task: .collection),
            prompt: prompt
        )
        var summary = generated.noteSummary()
        var limitations = SummaryLimitations()
        limitations.isShortened = notes.isShortened
        summary.processingNotes = limitations.messages
        await fillTemplateSections(of: &summary, request: request, source: prompt)
        progress(1)
        return summary
    }
}
