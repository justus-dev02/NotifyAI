//
//  FoundationModelSummarizer.swift
//  NotifyAISummarization
//

import Foundation
import FoundationModels
import NotifyAICore
import NotifyAISupport
import OSLog

/// Summarizes with Apple's on-device foundation model (Apple Intelligence).
///
/// The model has a small context window, so long texts are processed map-reduce style:
/// every chunk is condensed into structured notes, the notes are merged until they fit
/// into one request, and a final request turns them into the summary. Structured output
/// (`@Generable`) replaces fragile parsing of free text.
///
/// Failures stay local: an excerpt the model cannot process (e.g. a guardrail violation)
/// is condensed from its key sentences instead, and notes that do not fit even after
/// merging are shortened. Both are recorded (`NoteSummary.processingNotes`,
/// `ChapterDigest.failedExcerpts` / `wasShortened`) and shown to the user. Only when the
/// model fails on every excerpt does the whole request fail, and `SummarizationService`
/// falls back to the extractive summary.
struct FoundationModelSummarizer: Summarizer {
    /// Sends the requests; tests replace it.
    let responder: any LanguageModelResponder
    /// Measures text in tokens; `nil` uses the model's tokenizer where available.
    private let customMeasure: TextChunker.Measure?

    package init(responder: any LanguageModelResponder = SystemLanguageModelResponder(), measure: TextChunker.Measure? = nil) {
        self.responder = responder
        self.customMeasure = measure
    }

    /// Tokens available for the input of one request. The context window is 4096 tokens
    /// on iOS 26; instructions, the output schema and the response need the rest. Marked
    /// passages are part of this budget.
    static let inputTokenBudget = 1_800
    var inputTokenBudget: Int { Self.inputTokenBudget }
    /// At most this much of the input budget goes to the passages the user marked.
    let markedPassageBudget = 400
    /// At most this many marked passages are sent with a summary / a chapter.
    private let markedPassageLimit = 8
    private let chapterMarkedPassageLimit = 5

    package func summarize(_ request: SummaryRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> NoteSummary {
        let measure = tokenMeasure
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw SummarizationError.emptyInput
        }
        let marked = await markedSection(request.markedPassages, limit: markedPassageLimit, measure: measure)
        // The text shares the final request with the marked passages.
        let finalChunker = TextChunker(budget: inputTokenBudget - marked.tokens, measure: measure)
        var limitations = SummaryLimitations()
        limitations.omittedMarkedPassages = marked.omitted

        let generated: GeneratedSummary
        // What the template's own headings are filled from: the text, or the merged notes.
        let sectionSource: String
        if await measure(text) <= finalChunker.budget {
            progress(0.1)
            sectionSource = "Text:\n\n\(text)"
            generated = try await respond(
                generating: GeneratedSummary.self,
                instructions: Self.instructions(for: request, task: .summary),
                prompt: "Text:\n\n\(text)" + marked.text
            )
        } else {
            // Map: condense every chunk.
            let chunks = await TextChunker(budget: inputTokenBudget, measure: measure).chunks(of: text)
            let extracted = try await extractNotes(from: chunks, request: request) { fraction in
                progress(0.8 * fraction)
            }
            limitations.failedExcerpts = extracted.failed
            limitations.excerptCount = chunks.count

            // Reduce: merge notes until they fit into the final request.
            var reduced = try await reduce(extracted.notes, request: request, fitting: finalChunker)
            if reduced.text.isEmpty {
                // Nothing usable came back: summarize the beginning and say so.
                reduced = ReducedNotes(text: await finalChunker.chunks(of: text).first ?? "", isShortened: true)
            }
            limitations.isShortened = reduced.isShortened
            sectionSource = "Notes covering the whole content:\n\n\(reduced.text)"
            generated = try await respond(
                generating: GeneratedSummary.self,
                instructions: Self.instructions(for: request, task: .summary),
                prompt: sectionSource + marked.text
            )
        }
        var summary = generated.noteSummary()
        summary.processingNotes = limitations.messages
        await fillTemplateSections(of: &summary, request: request, source: sectionSource)
        progress(1)
        return summary
    }

    // MARK: - Chapters

    package func digest(_ chapter: ChapterRequest) async throws -> ChapterDigest {
        let measure = tokenMeasure
        let text = chapter.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SummarizationError.emptyInput }
        let marked = await markedSection(chapter.markedPassages, limit: chapterMarkedPassageLimit, measure: measure)
        let finalChunker = TextChunker(budget: inputTokenBudget - marked.tokens, measure: measure)

        // A chapter usually fits into one request; longer ones are condensed first.
        let source: String
        var failedExcerpts = 0
        var wasShortened = false
        if await measure(text) <= finalChunker.budget {
            source = "Transcript of chapter \(chapter.number) of \(chapter.count):\n\n\(text)"
        } else {
            let chunks = await TextChunker(budget: inputTokenBudget, measure: measure).chunks(of: text)
            let extracted = try await extractNotes(from: chunks, request: chapter.context) { _ in }
            failedExcerpts = extracted.failed
            var reduced = try await reduce(extracted.notes, request: chapter.context, fitting: finalChunker)
            if reduced.text.isEmpty {
                reduced = ReducedNotes(text: await finalChunker.chunks(of: text).first ?? "", isShortened: true)
            }
            wasShortened = reduced.isShortened
            source = "Notes covering chapter \(chapter.number) of \(chapter.count):\n\n\(reduced.text)"
        }

        let generated = try await respond(
            generating: GeneratedChapterDigest.self,
            instructions: Self.instructions(for: chapter.context, task: .chapter),
            prompt: source + marked.text
        )
        var digest = generated.chapterDigest()
        digest.failedExcerpts = failedExcerpts
        digest.wasShortened = wasShortened
        return digest
    }

    func combine(_ chapters: [TimedDigest], request: SummaryRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> NoteSummary {
        let chunker = TextChunker(budget: inputTokenBudget, measure: tokenMeasure)
        let texts = chapters.enumerated().map { index, chapter in
            Self.promptText(of: chapter, number: index + 1)
        }
        // Very long recordings: chapter notes are merged until they fit into one request.
        let notes = try await reduce(texts, request: request, fitting: chunker)
        progress(0.5)
        let source = "Chapter notes of a long recording, in chronological order:\n\n\(notes.text)"
        let generated = try await respond(
            generating: GeneratedSummary.self,
            instructions: Self.instructions(for: request, task: .summary),
            prompt: source
        )
        var summary = generated.noteSummary()
        var limitations = SummaryLimitations()
        limitations.isShortened = notes.isShortened
        summary.processingNotes = limitations.messages
        await fillTemplateSections(of: &summary, request: request, source: source)
        progress(1)
        return summary
    }

    private static func promptText(of chapter: TimedDigest, number: Int) -> String {
        let digest = chapter.digest
        var lines = ["Chapter \(number) (\(TimeFormatting.timestamp(chapter.start))–\(TimeFormatting.timestamp(chapter.end))): \(digest.title)"]
        if !digest.overview.isEmpty { lines.append("Summary: \(digest.overview)") }
        lines.append(notesText(keyPoints: digest.keyPoints, decisions: digest.decisions, actionItems: digest.actionItems, openQuestions: digest.openQuestions))
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: - Model access

    func respond<Content: Generable>(
        generating type: Content.Type,
        instructions: String,
        prompt: String
    ) async throws -> Content {
        try await responder.respond(generating: type, instructions: instructions, prompt: prompt)
    }

    var tokenMeasure: TextChunker.Measure {
        customMeasure ?? Self.systemTokenMeasure()
    }

    /// Uses the model's exact tokenizer where available (iOS / macOS 26.4) and falls back
    /// to a conservative estimate otherwise.
    private static func systemTokenMeasure() -> TextChunker.Measure {
        if #available(iOS 26.4, macOS 26.4, *) {
            return { text in
                if let count = try? await SystemLanguageModel.default.tokenCount(for: text) {
                    return count
                }
                return await TextChunker.estimatedTokens(text)
            }
        }
        return TextChunker.estimatedTokens
    }
}
