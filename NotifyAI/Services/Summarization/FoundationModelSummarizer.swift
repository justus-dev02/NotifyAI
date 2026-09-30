//
//  FoundationModelSummarizer.swift
//  NotifyAI
//

import Foundation
import FoundationModels
import NotifyAICore
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
    private let responder: any LanguageModelResponder
    /// Measures text in tokens; `nil` uses the model's tokenizer where available.
    private let customMeasure: TextChunker.Measure?

    init(responder: any LanguageModelResponder = SystemLanguageModelResponder(), measure: TextChunker.Measure? = nil) {
        self.responder = responder
        self.customMeasure = measure
    }

    /// Tokens available for the input of one request. The context window is 4096 tokens
    /// on iOS 26; instructions, the output schema and the response need the rest. Marked
    /// passages are part of this budget.
    static let inputTokenBudget = 1_800
    private var inputTokenBudget: Int { Self.inputTokenBudget }
    /// At most this much of the input budget goes to the passages the user marked.
    private let markedPassageBudget = 400
    /// At most this many marked passages are sent with a summary / a chapter.
    private let markedPassageLimit = 8
    private let chapterMarkedPassageLimit = 5

    func summarize(_ request: SummaryRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> NoteSummary {
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
        if await measure(text) <= finalChunker.budget {
            progress(0.1)
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
            generated = try await respond(
                generating: GeneratedSummary.self,
                instructions: Self.instructions(for: request, task: .summary),
                prompt: "Notes covering the whole content:\n\n\(reduced.text)" + marked.text
            )
        }
        progress(1)
        var summary = generated.noteSummary()
        summary.processingNotes = limitations.messages
        return summary
    }

    // MARK: - Chapters

    func digest(_ chapter: ChapterRequest) async throws -> ChapterDigest {
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
        let generated = try await respond(
            generating: GeneratedSummary.self,
            instructions: Self.instructions(for: request, task: .summary),
            prompt: "Chapter notes of a long recording, in chronological order:\n\n\(notes.text)"
        )
        progress(1)
        var summary = generated.noteSummary()
        var limitations = SummaryLimitations()
        limitations.isShortened = notes.isShortened
        summary.processingNotes = limitations.messages
        return summary
    }

    private static func promptText(of chapter: TimedDigest, number: Int) -> String {
        let digest = chapter.digest
        var lines = ["Chapter \(number) (\(TimeFormatting.timestamp(chapter.start))–\(TimeFormatting.timestamp(chapter.end))): \(digest.title)"]
        if !digest.overview.isEmpty { lines.append("Summary: \(digest.overview)") }
        lines.append(notesText(keyPoints: digest.keyPoints, decisions: digest.decisions, actionItems: digest.actionItems, openQuestions: digest.openQuestions))
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: - Map-reduce

    /// Condenses every chunk into notes, reporting progress from 0 to 1.
    ///
    /// A chunk the model cannot process is condensed from its key sentences instead, so a
    /// single refused excerpt never costs the whole summary. Only if the model fails on
    /// every chunk is its error thrown.
    private func extractNotes(
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
    private struct ReducedNotes {
        var text: String
        var isShortened: Bool
    }

    /// Merges notes in rounds until they fit into `target`. A group the model cannot merge
    /// stays as it is and is tried again in the next round. If the notes still do not fit
    /// after several rounds, they are cut, and the result says so.
    private func reduce(_ notes: [String], request: SummaryRequest, fitting target: TextChunker) async throws -> ReducedNotes {
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
    private static func extractiveNotes(from chunk: String, request: SummaryRequest) async -> String {
        var excerpt = request
        excerpt.text = chunk
        excerpt.markedPassages = []
        guard let summary = try? await ExtractiveSummarizer().summarize(excerpt, progress: { _ in }) else { return "" }
        return notesText(keyPoints: summary.keyPoints, decisions: summary.decisions, actionItems: summary.actionItems, openQuestions: summary.openQuestions)
    }

    /// The compact text representation of notes that is fed into the next request.
    static func notesText(keyPoints: [String], decisions: [String], actionItems: [ActionItem], openQuestions: [String]) -> String {
        var lines: [String] = []
        lines += keyPoints.map { "Point: \($0)" }
        lines += decisions.map { "Decision: \($0)" }
        lines += actionItems.map { item in
            var line = "Task: \(item.task)"
            if let owner = item.owner { line += " (owner: \(owner))" }
            if let due = item.due { line += " (due: \(due))" }
            return line
        }
        lines += openQuestions.map { "Open: \($0)" }
        return lines.joined(separator: "\n")
    }

    // MARK: - Marked passages

    /// The marked passages as a prompt section, limited to `markedPassageBudget` tokens so
    /// the request cannot exceed the context window.
    /// - Returns: The section (empty without passages), its size and how many non-empty
    ///   passages did not fit.
    private func markedSection(_ passages: [String], limit: Int, measure: TextChunker.Measure) async -> (text: String, tokens: Int, omitted: Int) {
        let candidates = passages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return ("", 0, 0) }
        let header = "\n\nThe user marked these passages as important; make sure they are reflected:"
        var used = await measure(header)
        var lines: [String] = []
        for passage in candidates.prefix(limit) {
            let line = "\n- \(passage)"
            let size = await measure(line)
            guard used + size <= markedPassageBudget else { continue }
            lines.append(line)
            used += size
        }
        let omitted = candidates.count - lines.count
        if omitted > 0 {
            Logger.summarization.info("\(omitted, privacy: .public) marked passages did not fit into the request")
        }
        guard !lines.isEmpty else { return ("", 0, omitted) }
        return (header + lines.joined(), used, omitted)
    }

    // MARK: - Model access

    private func respond<Content: Generable>(
        generating type: Content.Type,
        instructions: String,
        prompt: String
    ) async throws -> Content {
        try await responder.respond(generating: type, instructions: instructions, prompt: prompt)
    }

    private var tokenMeasure: TextChunker.Measure {
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

    // MARK: - Prompts

    private enum PromptTask {
        case summary, extractNotes, mergeNotes, chapter
    }

    private static func instructions(for request: SummaryRequest, task: PromptTask) -> String {
        // The language name is given in English ("German") to match the English instructions.
        let languageName = Locale(identifier: "en").localizedString(forLanguageCode: request.language.languageCode)
            ?? "the language of the text"
        let source = request.kind.hasAudio ? "a transcript of a spoken conversation" : "a document"

        let taskDescription = switch task {
        case .summary:
            "Summarize \(source) for the person who recorded it."
        case .extractNotes:
            "You receive one excerpt of \(source). Extract structured notes from this excerpt only."
        case .mergeNotes:
            "You receive several sets of notes about \(source). Merge them into one set: combine duplicates and keep every distinct fact, decision and task."
        case .chapter:
            "You receive one chapter of \(source). Condense this chapter only; other chapters are condensed separately."
        }

        let date = request.recordedAt.formatted(Date.FormatStyle(date: .complete, time: .shortened).locale(Locale(identifier: "en_US")))
        var context = "The content was recorded on \(date)."
        if !request.participants.isEmpty {
            context += " Participants: \(request.participants.joined(separator: ", "))."
        }
        if request.kind.hasAudio {
            context += " Lines starting with \"\(SourceSpeakerAttribution.userLabel):\" are spoken by the user who recorded; other labels are the other participants."
        }

        return """
        \(taskDescription)
        \(request.focus.modelGuidance)
        \(context)
        Only use information that is stated in the text. Never invent names, numbers, dates or facts. \
        Transcripts can contain recognition errors; interpret them sensibly and do not quote them verbatim.
        Be concrete: keep names, numbers, amounts, dates, deadlines and product or project names. \
        Avoid generic statements such as "various topics were discussed". \
        When a deadline is relative ("Friday", "next week"), keep it and add the calendar date based on the recording date.
        Write every field in \(languageName). Be concise and specific.
        """
    }
}

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

// MARK: - Structured output

@Generable(description: "Structured notes about part of a text")
struct PartialNotes {
    @Guide(description: "Important facts and statements, each as one short sentence", .maximumCount(8))
    var keyPoints: [String]

    @Guide(description: "Decisions that were explicitly made", .maximumCount(6))
    var decisions: [String]

    @Guide(description: "Concrete tasks someone committed to", .maximumCount(8))
    var actionItems: [GeneratedActionItem]

    @Guide(description: "Questions or problems that were left open", .maximumCount(5))
    var openQuestions: [String]

    /// Compact text representation used as input for the next reduce step.
    var promptText: String {
        FoundationModelSummarizer.notesText(
            keyPoints: keyPoints,
            decisions: decisions,
            actionItems: actionItems.map { ActionItem(task: $0.task, owner: $0.owner.nilIfEmpty, due: $0.due.nilIfEmpty) },
            openQuestions: openQuestions
        )
    }
}

@Generable(description: "A task that someone committed to")
struct GeneratedActionItem {
    @Guide(description: "The task, phrased as a short instruction")
    var task: String

    @Guide(description: "Name of the responsible person if it was mentioned, otherwise an empty string")
    var owner: String

    @Guide(description: "The deadline as it was mentioned, otherwise an empty string")
    var due: String
}

@Generable(description: "A topic that was discussed")
struct GeneratedTopic {
    @Guide(description: "A short topic title of at most five words")
    var title: String

    @Guide(description: "What was said about the topic", .maximumCount(4))
    var points: [String]
}

@Generable(description: "The condensed content of one chapter of a long recording")
struct GeneratedChapterDigest {
    @Guide(description: "A specific chapter title of at most six words naming its main subject")
    var title: String

    @Guide(description: "One or two sentences on what this chapter is about and its outcome")
    var overview: String

    @Guide(description: "The most important points of this chapter", .maximumCount(5))
    var keyPoints: [String]

    @Guide(description: "Decisions that were explicitly made in this chapter", .maximumCount(4))
    var decisions: [String]

    @Guide(description: "Concrete tasks someone committed to in this chapter", .maximumCount(6))
    var actionItems: [GeneratedActionItem]

    @Guide(description: "Questions or problems left open in this chapter", .maximumCount(3))
    var openQuestions: [String]

    func chapterDigest() -> ChapterDigest {
        ChapterDigest(
            title: title.cleaned,
            overview: overview.cleaned,
            keyPoints: keyPoints.cleaned,
            decisions: decisions.cleaned,
            actionItems: actionItems.compactMap { item in
                let task = item.task.cleaned
                guard !task.isEmpty else { return nil }
                return ActionItem(task: task, owner: item.owner.cleaned.nilIfEmpty, due: item.due.cleaned.nilIfEmpty)
            },
            openQuestions: openQuestions.cleaned,
            source: .appleIntelligence
        )
    }
}

@Generable(description: "Summary of a conversation or document")
struct GeneratedSummary {
    @Guide(description: "A specific title of at most seven words")
    var title: String

    @Guide(description: "Two to four sentences describing what the content is about and its outcome")
    var overview: String

    @Guide(description: "The most important points", .maximumCount(7))
    var keyPoints: [String]

    @Guide(description: "Decisions that were explicitly made", .maximumCount(6))
    var decisions: [String]

    @Guide(description: "Concrete tasks someone committed to", .maximumCount(10))
    var actionItems: [GeneratedActionItem]

    @Guide(description: "Questions or problems that were left open", .maximumCount(5))
    var openQuestions: [String]

    @Guide(description: "The main topics in the order they came up", .maximumCount(5))
    var topics: [GeneratedTopic]

    @Guide(description: "One to three keywords that identify this content, e.g. the main subject, project, product or customer. Each one to three words, no dates, no generic words like meeting or discussion", .maximumCount(3))
    var keywords: [String]

    func noteSummary() -> NoteSummary {
        NoteSummary(
            suggestedTitle: title.cleaned.nilIfEmpty,
            overview: overview.cleaned,
            keyPoints: keyPoints.cleaned,
            decisions: decisions.cleaned,
            actionItems: actionItems.compactMap { item in
                let task = item.task.cleaned
                guard !task.isEmpty else { return nil }
                return ActionItem(task: task, owner: item.owner.cleaned.nilIfEmpty, due: item.due.cleaned.nilIfEmpty)
            },
            openQuestions: openQuestions.cleaned,
            topics: topics.compactMap { topic in
                let title = topic.title.cleaned
                guard !title.isEmpty else { return nil }
                return SummaryTopic(title: title, points: topic.points.cleaned)
            },
            source: .appleIntelligence,
            keywords: keywords.cleaned
        )
    }
}

private extension String {
    var cleaned: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension [String] {
    var cleaned: [String] { map(\.cleaned).filter { !$0.isEmpty } }
}
