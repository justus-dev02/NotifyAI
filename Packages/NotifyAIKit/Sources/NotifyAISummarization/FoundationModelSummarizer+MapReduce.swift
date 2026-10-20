//
//  FoundationModelSummarizer+MapReduce.swift
//  NotifyAISummarization
//

import Foundation
import NotifyAICore
import OSLog

/// Long texts: every excerpt is condensed into notes, and the notes are merged until they fit
/// into one request. An excerpt the model refuses is condensed from its key sentences.
extension FoundationModelSummarizer {
    /// Condenses every chunk into notes, reporting progress from 0 to 1.
    ///
    /// A chunk the model cannot process is condensed from its key sentences instead, so a
    /// single refused excerpt never costs the whole summary. Only if the model fails on
    /// every chunk is its error thrown.
    func extractNotes(
        from chunks: [String],
        request: SummaryRequest,
        progress: (Double) -> Void
    ) async throws -> (notes: [String], failed: Int) {
        var notes: [String] = []
        var failed = 0
        var lastError: (any Error)?
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            do {
                let partial = try await respond(
                    generating: PartialNotes.self,
                    instructions: Self.instructions(for: request, task: .extractNotes),
                    prompt: "Excerpt \(index + 1) of \(chunks.count):\n\n\(chunk)"
                )
                notes.append(partial.promptText)
            } catch {
                try Task.checkCancellation()
                Logger.summarization.error("Excerpt \(index + 1, privacy: .public) of \(chunks.count, privacy: .public) failed, condensing it without the model: \(error.localizedDescription, privacy: .public)")
                failed += 1
                lastError = error
                notes.append(await Self.extractiveNotes(from: chunk, request: request))
            }
            progress(Double(index + 1) / Double(chunks.count))
        }
        if failed == chunks.count, let lastError {
            throw lastError
        }
        return (notes.filter { !$0.isEmpty }, failed)
    }

    /// Notes merged until they fit into `target`, and whether they had to be cut.
    struct ReducedNotes {
        package var text: String
        var isShortened: Bool
    }

    /// Merges notes in rounds until they fit into `target`. A group the model cannot merge
    /// stays as it is and is tried again in the next round. If the notes still do not fit
    /// after several rounds, they are cut, and the result says so.
    func reduce(_ notes: [String], request: SummaryRequest, fitting target: TextChunker) async throws -> ReducedNotes {
        // Merge requests carry no marked passages, so a group may use the whole budget.
        let groupChunker = TextChunker(budget: inputTokenBudget, measure: target.measure)
        var texts = notes
        for _ in 0..<4 {
            let joined = texts.joined(separator: "\n\n")
            if await target.measure(joined) <= target.budget {
                return ReducedNotes(text: joined, isShortened: false)
            }
            var merged: [String] = []
            for group in await groupChunker.chunks(of: joined) {
                try Task.checkCancellation()
                do {
                    let partial = try await respond(
                        generating: PartialNotes.self,
                        instructions: Self.instructions(for: request, task: .mergeNotes),
                        prompt: group
                    )
                    merged.append(partial.promptText)
                } catch {
                    try Task.checkCancellation()
                    Logger.summarization.error("Merging notes failed, keeping them unmerged: \(error.localizedDescription, privacy: .public)")
                    merged.append(group)
                }
            }
            texts = merged
        }
        let joined = texts.joined(separator: "\n\n")
        if await target.measure(joined) <= target.budget {
            return ReducedNotes(text: joined, isShortened: false)
        }
        // Still too long after several rounds: keep what fits and say so.
        let kept = await target.chunks(of: joined).first ?? ""
        Logger.summarization.error("Notes still too long after merging; keeping \(kept.count, privacy: .public) of \(joined.count, privacy: .public) characters")
        return ReducedNotes(text: kept, isShortened: true)
    }

    /// Key sentences of an excerpt the model could not process, in the format of `PartialNotes`.
    static func extractiveNotes(from chunk: String, request: SummaryRequest) async -> String {
        var excerpt = request
        excerpt.text = chunk
        excerpt.markedPassages = []
        guard let summary = try? await ExtractiveSummarizer().summarize(excerpt, progress: { _ in }) else { return "" }
        return notesText(keyPoints: summary.keyPoints, decisions: summary.decisions, actionItems: summary.actionItems, openQuestions: summary.openQuestions)
    }

    /// At most this many characters of a task's quote are passed on between requests.
    static let quoteLength = 140

    /// The compact text representation of notes that is fed into the next request.
    static func notesText(keyPoints: [String], decisions: [String], actionItems: [ActionItem], openQuestions: [String]) -> String {
        var lines: [String] = []
        lines += keyPoints.map { "Point: \($0)" }
        lines += decisions.map { "Decision: \($0)" }
        lines += actionItems.map { item in
            var line = "Task: \(item.task)"
            if let owner = item.owner { line += " (owner: \(owner))" }
            if let due = item.due { line += " (due: \(due))" }
            // The quote travels with the task, so the final summary can still cite the text.
            if let evidence = item.evidence { line += " (quote: \"\(evidence.prefix(Self.quoteLength))\")" }
            return line
        }
        lines += openQuestions.map { "Open: \($0)" }
        return lines.joined(separator: "\n")
    }
}
