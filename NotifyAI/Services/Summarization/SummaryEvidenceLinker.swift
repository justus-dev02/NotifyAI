//
//  SummaryEvidenceLinker.swift
//  NotifyAI
//

import Foundation
import NotifyAICore

/// Finds the transcript position that supports each key point, decision, task and open
/// question of a summary, so the user can check it with one tap.
///
/// A summary item and a transcript window match when they share content words (after the
/// same normalization the search uses) or mean the same (sentence embeddings). Items without
/// a clear match get no link rather than a wrong one.
struct SummaryEvidenceLinker: Sendable {
    let embedder: SentenceEmbedder

    /// Share of an item's content words that must occur in the window.
    var minimumTermOverlap = 0.34
    /// Cosine similarity that counts as a match on its own.
    var minimumSimilarity: Float = 0.8

    func sourceTimes(for summary: NoteSummary, segments: [TranscriptSegment], languageCode: String) -> [String: TimeInterval] {
        guard !segments.isEmpty else { return [:] }
        let windows = makeWindows(segments, languageCode: languageCode)
        let items = summary.keyPoints + summary.decisions + summary.actionItems.map(\.task) + summary.openQuestions

        var result: [String: TimeInterval] = [:]
        for item in items where result[item] == nil {
            if let time = bestMatch(for: item, in: windows, languageCode: languageCode) {
                result[item] = time
            }
        }
        return result
    }

    // MARK: - Private

    private struct Window {
        let start: TimeInterval
        let terms: Set<String>
        let vector: EmbeddingVector?
    }

    /// Two consecutive segments per window: statements often span a segment boundary.
    private func makeWindows(_ segments: [TranscriptSegment], languageCode: String) -> [Window] {
        segments.indices.map { index in
            let text = segments[index...min(index + 1, segments.count - 1)].map(\.text).joined(separator: " ")
            return Window(
                start: segments[index].start,
                terms: Set(TextAnalysis.terms(in: text, languageCode: languageCode)),
                vector: embedder.vector(for: text, languageCode: languageCode)
            )
        }
    }

    private func bestMatch(for item: String, in windows: [Window], languageCode: String) -> TimeInterval? {
        let itemTerms = Set(TextAnalysis.terms(in: item, languageCode: languageCode))
        let itemVector = embedder.vector(for: item, languageCode: languageCode)
        guard !itemTerms.isEmpty || itemVector != nil else { return nil }

        var best: (score: Double, start: TimeInterval)?
        for window in windows {
            let overlap = itemTerms.isEmpty ? 0 : Double(itemTerms.intersection(window.terms).count) / Double(itemTerms.count)
            let similarity = itemVector.flatMap { vector in window.vector.map { vector.similarity(to: $0) } } ?? 0
            guard overlap >= minimumTermOverlap || similarity >= minimumSimilarity else { continue }
            let score = 0.6 * overlap + 0.4 * Double(max(0, similarity))
            if score > (best?.score ?? -1) {
                best = (score, window.start)
            }
        }
        return best?.start
    }
}
