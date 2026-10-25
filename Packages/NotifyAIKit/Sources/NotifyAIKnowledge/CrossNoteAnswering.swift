//
//  CrossNoteAnswering.swift
//  NotifyAIKnowledge
//

import Foundation
import NotifyAICore
import NotifyAISummarization
import NotifyAISupport

/// Answers a question whose answer is spread over several notes: "Was wurde mit Samsung bisher
/// entschieden?", "Welche Aufgaben aus den Meetings mit Anna sind noch offen?", "Wie hat sich
/// das Budget entwickelt?".
///
/// The few best passages that answer a single fact would leave out whole meetings and still
/// sound complete. Here every matching note contributes on its own:
/// 1. **Context per note** – its summary (decisions, tasks, open questions cover the whole
///    note) and its passages that answer the question, at most `noteContextCharacters`.
/// 2. **Map** – if all contexts fit into one request, they are its sources as they are.
///    Otherwise the language model extracts from each note what it says about the question.
///    Points that share no content word with their note are dropped (`SummaryGrounding`); a
///    note the model fails on contributes its best passage instead.
/// 3. **Reduce** – one request combines the notes, oldest first, so changes over time and the
///    current status are visible, and cites every note it uses.
///
/// At most `maximumNotes` notes are read, the best of the search; the caller reports the rest.
@MainActor
struct CrossNoteAnswering {
    /// What is happening, for the pending message.
    enum Step: Equatable, Sendable {
        case reading(note: Int, count: Int)
        case combining(notes: Int)
    }

    /// One note as the combining request sees it.
    struct NoteSource: Sendable {
        let number: Int
        let hit: NoteHit
        /// Its best passage: what its source card shows and where it opens.
        let passage: PassageHit?
        /// Its context, or what the model extracted from it.
        let text: String
    }

    struct Outcome: Sendable {
        var answer: AssistantAnswer
        /// The notes the answer was made from, numbered oldest first.
        var sources: [NoteSource]
        /// Notes the model could not read; their best passage stood in.
        var failedNotes = 0
        /// Notes whose findings were cut to fit into the combining request.
        var shortenedNotes = 0
    }

    let assistant: any NoteAssistant
    let language: TranscriptionLanguage

    /// Every note beyond those that fit into one request costs a request of its own.
    static let maximumNotes = 6
    /// Passages to search for, so every note read has its own (at most three per note).
    static let passageLimit = maximumNotes * 3
    /// One note's context, about 1 500 tokens: a request also holds instructions and findings.
    var noteContextCharacters = 4_500
    /// All sources of the combining request, about as many tokens as a single answer gets.
    var sourceCharacters = NoteQuestionAnswering.sourceTokenBudget * 3
    /// The summary leaves at least half of a note's context to its passages.
    private var summaryCharacters: Int { noteContextCharacters / 2 }

    /// The notes worth reading: everything but summaries across notes, whose notes are found
    /// themselves and would otherwise count twice.
    static func readableNotes(in result: SearchResult) -> [NoteHit] {
        result.notes.filter { $0.note.kind != .collection }
    }

    func answer(
        _ question: String,
        from result: SearchResult,
        history: [ChatTurn],
        now: Date,
        progress: (Step) -> Void
    ) async throws -> Outcome {
        let notes = Array(Self.readableNotes(in: result).prefix(Self.maximumNotes))
        let contexts = notes.map { context(of: $0.note, passages: result.passages) }
        let passages = notes.map { hit in result.passages.first { $0.note.id == hit.note.id } }

        var outcome = Outcome(answer: AssistantAnswer(text: "", citedSources: [], isAnswerFound: false), sources: [])
        var texts: [String?]
        if contexts.reduce(0, { $0 + $1.count }) <= sourceCharacters {
            texts = contexts
        } else {
            texts = []
            for (position, hit) in notes.enumerated() {
                try Task.checkCancellation()
                progress(.reading(note: position + 1, count: notes.count))
                do {
                    let findings = try await assistant.findings(
                        question: question,
                        in: source(number: position + 1, hit: hit, text: contexts[position]),
                        language: language,
                        now: now
                    )
                    let grounding = SummaryGrounding(text: contexts[position], languageCode: hit.note.languageCode)
                    let points = findings.isRelevant ? findings.points.filter(grounding.isSupported) : []
                    texts.append(points.isEmpty ? nil : points.map { "- \($0)" }.joined(separator: "\n"))
                } catch {
                    try Task.checkCancellation()
                    outcome.failedNotes += 1
                    texts.append(passages[position].map { "- \($0.passage.text)" })
                }
            }
            outcome.shortenedNotes = fit(&texts)
        }

        // Oldest first: the combining request sees how things developed.
        let read = notes.indices
            .compactMap { position in texts[position].map { (notes[position], passages[position], $0) } }
            .sorted { $0.0.note.createdAt < $1.0.note.createdAt }
        outcome.sources = read.enumerated().map { offset, entry in
            NoteSource(number: offset + 1, hit: entry.0, passage: entry.1, text: entry.2)
        }
        guard !outcome.sources.isEmpty else { return outcome }

        try Task.checkCancellation()
        progress(.combining(notes: outcome.sources.count))
        outcome.answer = try await assistant.answerAcrossNotes(
            question: question,
            notes: outcome.sources.map { source(number: $0.number, hit: $0.hit, text: $0.text) },
            history: history,
            language: language,
            now: now
        )
        return outcome
    }

    // MARK: - Context

    /// The note's summary, then its passages that answer the question in the order of the note.
    func context(of note: IndexedNote, passages: [PassageHit]) -> String {
        var parts: [String] = []
        var remaining = noteContextCharacters
        let summary = note.passages.filter { $0.kind == .summary }.map(\.text).joined(separator: "\n")
        if !summary.isEmpty {
            let kept = Self.prefix(of: summary, maximumCharacters: summaryCharacters)
            parts.append("Summary:\n\(kept)")
            remaining -= kept.count
        }
        let excerpts = passages
            .filter { $0.note.id == note.id && $0.passage.kind != .summary }
            .sorted { ($0.passage.start ?? 0, $0.passage.id) < ($1.passage.start ?? 0, $1.passage.id) }
        var kept: [String] = []
        for hit in excerpts {
            var text = hit.passage.text
            if let start = hit.passage.start {
                text = "(\(TimeFormatting.timestamp(start))) " + text
            }
            guard text.count <= remaining else { break }
            kept.append(text)
            remaining -= text.count
        }
        if !kept.isEmpty {
            parts.append("Excerpts:\n" + kept.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// Cuts the findings until all fit into the combining request: points are removed from the
    /// end of the least relevant notes first (the notes are in search order). A note keeps at
    /// least its first point. Returns how many notes lost points.
    private func fit(_ texts: inout [String?]) -> Int {
        func total() -> Int { texts.reduce(0) { $0 + ($1?.count ?? 0) } }
        var shortened = Set<Int>()
        for position in texts.indices.reversed() {
            guard total() > sourceCharacters else { break }
            guard var lines = texts[position]?.split(separator: "\n").map(String.init) else { continue }
            while lines.count > 1, total() > sourceCharacters {
                lines.removeLast()
                texts[position] = lines.joined(separator: "\n")
                shortened.insert(position)
            }
        }
        // Still too long (very long single points): cut every note to its share.
        if total() > sourceCharacters {
            let share = sourceCharacters / max(1, texts.compactMap { $0 }.count)
            for position in texts.indices {
                guard let text = texts[position], text.count > share else { continue }
                texts[position] = Self.prefix(of: text, maximumCharacters: share)
                shortened.insert(position)
            }
        }
        return shortened.count
    }

    private func source(number: Int, hit: NoteHit, text: String) -> AssistantSource {
        AssistantSource(number: number, noteTitle: hit.note.title, noteDate: hit.note.createdAt, labels: hit.note.labels, start: nil, text: text)
    }

    /// The text, or its beginning up to the last line or sentence end, marked with " …"; never
    /// longer than `maximumCharacters`.
    static func prefix(of text: String, maximumCharacters: Int) -> String {
        guard text.count > maximumCharacters else { return text }
        let head = text.prefix(max(0, maximumCharacters - 2))
        if let end = head.lastIndex(where: { $0 == "\n" || $0 == "." || $0 == ";" }), head.distance(from: head.startIndex, to: end) > maximumCharacters / 2 {
            return String(head[...end]).trimmingCharacters(in: .whitespacesAndNewlines) + " …"
        }
        return String(head) + " …"
    }
}
