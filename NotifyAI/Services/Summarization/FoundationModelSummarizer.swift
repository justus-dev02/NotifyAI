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
struct FoundationModelSummarizer: Summarizer {
    /// Tokens available for the text of one request. The context window is 4096 tokens
    /// on iOS 26; instructions, the output schema and the response need the rest.
    private let inputTokenBudget = 1_800

    func summarize(_ request: SummaryRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> NoteSummary {
        let chunker = TextChunker(budget: inputTokenBudget, measure: Self.tokenMeasure())
        let chunks = await chunker.chunks(of: request.text)
        guard !chunks.isEmpty else {
            throw SummarizationError.emptyInput
        }

        let generated: GeneratedSummary
        if chunks.count == 1 {
            progress(0.1)
            generated = try await respond(
                generating: GeneratedSummary.self,
                instructions: Self.instructions(for: request, task: .summary),
                prompt: Self.summaryPrompt(source: chunks[0], sourceIsNotes: false, request: request)
            )
        } else {
            // Map: condense every chunk.
            var notes: [PartialNotes] = []
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                let partial = try await respond(
                    generating: PartialNotes.self,
                    instructions: Self.instructions(for: request, task: .extractNotes),
                    prompt: "Excerpt \(index + 1) of \(chunks.count):\n\n\(chunk)"
                )
                notes.append(partial)
                progress(0.8 * Double(index + 1) / Double(chunks.count))
            }

            // Reduce: merge notes until they fit into a single request.
            var notesText = await reduce(notes, request: request, chunker: chunker)
            if notesText.isEmpty {
                notesText = chunks[0]
            }
            generated = try await respond(
                generating: GeneratedSummary.self,
                instructions: Self.instructions(for: request, task: .summary),
                prompt: Self.summaryPrompt(source: notesText, sourceIsNotes: true, request: request)
            )
        }
        progress(1)
        return generated.noteSummary()
    }

    // MARK: - Chapters

    func digest(_ chapter: ChapterRequest) async throws -> ChapterDigest {
        let chunker = TextChunker(budget: inputTokenBudget, measure: Self.tokenMeasure())
        let chunks = await chunker.chunks(of: chapter.text)
        guard !chunks.isEmpty else { throw SummarizationError.emptyInput }

        // A chapter usually fits into one or two requests; longer ones are condensed first.
        let source: String
        if chunks.count == 1 {
            source = "Transcript of chapter \(chapter.number) of \(chapter.count):\n\n\(chunks[0])"
        } else {
            var notes: [String] = []
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                let partial = try await respond(
                    generating: PartialNotes.self,
                    instructions: Self.instructions(for: chapter.context, task: .extractNotes),
                    prompt: "Excerpt \(index + 1) of \(chunks.count):\n\n\(chunk)"
                )
                notes.append(partial.promptText)
            }
            let merged = await reduce(notes, request: chapter.context, chunker: chunker)
            source = "Notes covering chapter \(chapter.number) of \(chapter.count):\n\n\(merged)"
        }

        var prompt = source
        let marked = chapter.markedPassages.prefix(5).filter { !$0.isEmpty }
        if !marked.isEmpty {
            prompt += "\n\nThe user marked these passages as important; make sure they are reflected:\n"
            prompt += marked.map { "- \($0)" }.joined(separator: "\n")
        }
        let generated = try await respond(
            generating: GeneratedChapterDigest.self,
            instructions: Self.instructions(for: chapter.context, task: .chapter),
            prompt: prompt
        )
        return generated.chapterDigest()
    }

    func combine(_ chapters: [TimedDigest], request: SummaryRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> NoteSummary {
        let chunker = TextChunker(budget: inputTokenBudget, measure: Self.tokenMeasure())
        let texts = chapters.enumerated().map { index, chapter in
            Self.promptText(of: chapter, number: index + 1)
        }
        let joined = texts.joined(separator: "\n\n")
        // Very long recordings: chapter notes are merged until they fit into one request.
        let notes = await chunker.chunks(of: joined).count <= 1 ? joined : await reduce(texts, request: request, chunker: chunker)
        progress(0.5)
        let generated = try await respond(
            generating: GeneratedSummary.self,
            instructions: Self.instructions(for: request, task: .summary),
            prompt: "Chapter notes of a long recording, in chronological order:\n\n\(notes)"
        )
        progress(1)
        return generated.noteSummary()
    }

    private static func promptText(of chapter: TimedDigest, number: Int) -> String {
        let digest = chapter.digest
        var lines = ["Chapter \(number) (\(TimeFormatting.timestamp(chapter.start))–\(TimeFormatting.timestamp(chapter.end))): \(digest.title)"]
        if !digest.overview.isEmpty { lines.append("Summary: \(digest.overview)") }
        lines += digest.keyPoints.map { "Point: \($0)" }
        lines += digest.decisions.map { "Decision: \($0)" }
        lines += digest.actionItems.map { item in
            var line = "Task: \(item.task)"
            if let owner = item.owner { line += " (owner: \(owner))" }
            if let due = item.due { line += " (due: \(due))" }
            return line
        }
        lines += digest.openQuestions.map { "Open: \($0)" }
        return lines.joined(separator: "\n")
    }

    // MARK: - Map-reduce

    private func reduce(_ notes: [PartialNotes], request: SummaryRequest, chunker: TextChunker) async -> String {
        await reduce(notes.map(\.promptText), request: request, chunker: chunker)
    }

    private func reduce(_ notes: [String], request: SummaryRequest, chunker: TextChunker) async -> String {
        var texts = notes
        // Each round merges groups of notes; the loop ends once everything fits.
        for _ in 0..<4 {
            let joined = texts.joined(separator: "\n\n")
            let groups = await chunker.chunks(of: joined)
            if groups.count <= 1 {
                return joined
            }
            var merged: [String] = []
            for group in groups {
                if Task.isCancelled { break }
                do {
                    let partial = try await respond(
                        generating: PartialNotes.self,
                        instructions: Self.instructions(for: request, task: .mergeNotes),
                        prompt: group
                    )
                    merged.append(partial.promptText)
                } catch {
                    Logger.summarization.error("Merging notes failed: \(error.localizedDescription, privacy: .public)")
                    merged.append(group)
                }
            }
            texts = merged
        }
        // Still too long after several rounds: keep what fits.
        return await chunker.chunks(of: texts.joined(separator: "\n\n")).first ?? ""
    }

    // MARK: - Model access

    private func respond<Content: Generable>(
        generating type: Content.Type,
        instructions: String,
        prompt: String
    ) async throws -> Content {
        // A fresh session per request: the transcript must not accumulate in the context.
        let session = LanguageModelSession(instructions: instructions)
        // Low temperature: summaries should reproduce the content, not vary it.
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 1_000)
        let response = try await session.respond(to: prompt, generating: type, options: options)
        return response.content
    }

    /// Uses the model's exact tokenizer where available (iOS / macOS 26.4) and falls back
    /// to a conservative estimate otherwise.
    private static func tokenMeasure() -> TextChunker.Measure {
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

    private static func summaryPrompt(source: String, sourceIsNotes: Bool, request: SummaryRequest) -> String {
        var prompt = sourceIsNotes
            ? "Notes covering the whole content:\n\n\(source)"
            : "Text:\n\n\(source)"
        let marked = request.markedPassages.prefix(8).filter { !$0.isEmpty }
        if !marked.isEmpty {
            prompt += "\n\nThe user marked these passages as important; make sure they are reflected:\n"
            prompt += marked.map { "- \($0)" }.joined(separator: "\n")
        }
        return prompt
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
        var lines: [String] = []
        lines += keyPoints.map { "Point: \($0)" }
        lines += decisions.map { "Decision: \($0)" }
        lines += actionItems.map { item in
            var line = "Task: \(item.task)"
            if !item.owner.isEmpty { line += " (owner: \(item.owner))" }
            if !item.due.isEmpty { line += " (due: \(item.due))" }
            return line
        }
        lines += openQuestions.map { "Open: \($0)" }
        return lines.joined(separator: "\n")
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
