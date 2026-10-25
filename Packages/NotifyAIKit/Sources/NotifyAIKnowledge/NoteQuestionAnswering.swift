//
//  NoteQuestionAnswering.swift
//  NotifyAIKnowledge
//

import Foundation
import NotifyAICore
import NotifyAISettings
import NotifyAISummarization
import NotifyAISupport
import OSLog

/// Answers one question about the notes: understands it, searches, and lets the language
/// model answer from the passages found – or, for questions spread over several notes, from
/// every matching note (`CrossNoteAnswering`) – or shows them, or offers a summary across the
/// notes found. Stateless; `NoteChatModel` keeps the conversation.
@MainActor
struct NoteQuestionAnswering {
    let knowledge: KnowledgeIndexService
    let settings: AppSettings
    let assistant: any NoteAssistant
    let availability: @Sendable (TranscriptionLanguage) -> LanguageModelAvailability
    private let logger = Logger.summarization

    /// Tokens for the sources of one answer. The on-device model has a context of 4096
    /// tokens; instructions, question, history and the answer need the rest.
    static let sourceTokenBudget = 2_000
    static let maximumSourceCharacters = 900
    static let maximumSources = 8
    /// At most this many notes are offered for a summary across several notes.
    static let maximumCollectionNotes = 40

    init(
        knowledge: KnowledgeIndexService,
        settings: AppSettings,
        assistant: any NoteAssistant,
        availability: @escaping @Sendable (TranscriptionLanguage) -> LanguageModelAvailability
    ) {
        self.knowledge = knowledge
        self.settings = settings
        self.assistant = assistant
        self.availability = availability
    }

    var modelAvailability: LanguageModelAvailability {
        availability(settings.transcription.language)
    }

    /// Answers one question. `progress` describes longer steps for the pending message.
    func respond(to question: String, history: [ChatTurn], now date: Date, progress: (String) -> Void = { _ in }) async -> ChatMessage {
        await knowledge.refreshAndWait()
        let index = knowledge.index
        guard !index.notes.isEmpty else {
            return ChatMessage(
                role: .assistant,
                text: String(localized: "Es gibt noch keine fertigen Notizen, die ich durchsuchen kann. Sobald eine Aufnahme oder ein Import verarbeitet ist, kannst du hier Fragen dazu stellen.", bundle: .module)
            )
        }

        let canUseModel = modelAvailability == .available
        let plan = await makePlan(for: question, history: history, index: index, now: date, useModel: canUseModel)
        let request = SearchRequest(
            text: plan.searchText,
            expansions: plan.expansions,
            filters: plan.filters,
            languageCode: settings.transcription.language.languageCode
        )
        let noteLimit = plan.wantsCollectionSummary ? Self.maximumCollectionNotes : 10
        let passageLimit = plan.spansNotes ? CrossNoteAnswering.passageLimit : 12
        let result = await Self.search(request, in: index, embedder: knowledge.embedder, passageLimit: passageLimit, noteLimit: noteLimit)

        var message = ChatMessage(role: .assistant, text: "", filters: plan.filterDescriptions)
        message.notes = result.notes.map {
            ChatNoteLink(noteID: $0.note.id, title: $0.note.title, date: $0.note.createdAt, kind: $0.note.kind, reasons: $0.reasons)
        }
        if !result.relaxedPersons.isEmpty {
            message.notice = String(localized: "Keine Notiz erwähnt \(result.relaxedPersons.joined(separator: ", ")). Ich habe ohne diesen Filter gesucht.", bundle: .module)
        }
        if !result.relaxedLabels.isEmpty {
            Self.append(String(localized: "Keine Notiz hat das Label \(result.relaxedLabels.joined(separator: ", ")). Ich habe danach im Text gesucht.", bundle: .module), to: &message)
        }

        guard result.candidateCount > 0 else {
            message.text = String(localized: "Für diese Filter gibt es keine Notizen.", bundle: .module)
            return message
        }
        guard !result.passages.isEmpty || !result.notes.isEmpty else {
            message.text = String(localized: "Dazu habe ich in deinen Notizen nichts gefunden.", bundle: .module)
            return message
        }

        if plan.wantsCollectionSummary, Self.offerCollection(of: result, in: &message) {
            return message
        }

        // Lists ("Zeig mir alle Meetings mit Anna") need no generated answer.
        let isListing = plan.wantsList || TextAnalysis.terms(in: plan.searchText, languageCode: request.languageCode).isEmpty && plan.expansions.isEmpty
        if isListing {
            message.text = result.notes.count == 1
                ? String(localized: "Ich habe eine passende Notiz gefunden.", bundle: .module)
                : String(localized: "Ich habe \(result.notes.count) passende Notizen gefunden.", bundle: .module)
            return message
        }

        if plan.spansNotes, canUseModel, CrossNoteAnswering.readableNotes(in: result).count >= 2 {
            await answerAcrossNotes(question, from: result, history: history, now: date, progress: progress).apply(to: &message)
            return message
        }

        let sources = selectSources(from: result.passages)
        guard canUseModel else {
            message.text = String(localized: "Das sind die passendsten Stellen in deinen Notizen:", bundle: .module)
            message.sources = Array(sources.prefix(5))
            message.notice = [message.notice, Self.unavailableNotice(modelAvailability)].compactMap { $0 }.joined(separator: " ")
            return message
        }

        await answer(question, from: sources, history: history, now: date, into: &message)
        return message
    }

    /// "Fasse alle Samsung-Meetings zusammen": a few excerpts would make an incomplete answer
    /// that sounds complete. The notes are offered for a summary across all of them, which
    /// reads every note's whole summary.
    /// - Returns: Whether there are enough notes to offer one.
    private static func offerCollection(of result: SearchResult, in message: inout ChatMessage) -> Bool {
        let summarizable = result.notes.filter { $0.note.kind != .collection }
        guard summarizable.count >= 2 else { return false }
        message.collectionNoteIDs = summarizable.map(\.note.id)
        message.text = String(localized: "Ich habe \(summarizable.count) passende Notizen gefunden. Eine Zusammenfassung über alle liest jede Notiz vollständig, nicht nur einzelne Stellen; prüfe die Auswahl und starte sie unten.", bundle: .module)
        return true
    }

    @concurrent
    private static func search(
        _ request: SearchRequest,
        in index: KnowledgeIndex,
        embedder: any SentenceEmbedding,
        passageLimit: Int,
        noteLimit: Int
    ) async -> SearchResult {
        HybridRetriever(index: index, embedder: embedder).search(request, passageLimit: passageLimit, noteLimit: noteLimit)
    }

    /// What an answer across notes adds to the message.
    private struct CrossNoteReply {
        var text = ""
        var sources: [ChatSource] = []
        var notices: [String] = []

        func apply(to message: inout ChatMessage) {
            message.text = text
            message.sources = sources
            for notice in notices {
                NoteQuestionAnswering.append(notice, to: &message)
            }
        }
    }

    /// Reads every matching note on its own and combines what they say. Each cited note gets
    /// one source card, which shows and opens its best passage: the findings are the model's
    /// words, the card shows the note's own.
    private func answerAcrossNotes(
        _ question: String,
        from result: SearchResult,
        history: [ChatTurn],
        now date: Date,
        progress: (String) -> Void
    ) async -> CrossNoteReply {
        let answering = CrossNoteAnswering(assistant: assistant, language: settings.transcription.language)
        var reply = CrossNoteReply()
        let outcome: CrossNoteAnswering.Outcome
        do {
            outcome = try await answering.answer(question, from: result, history: history, now: date) { step in
                switch step {
                case .reading(let note, let count):
                    progress(String(localized: "Lese Notiz \(note) von \(count) …", bundle: .module))
                case .combining(let count):
                    progress(String(localized: "Führe \(count) Notizen zusammen …", bundle: .module))
                }
            }
        } catch is CancellationError {
            return reply
        } catch {
            logger.error("Answering a question across notes failed: \(error.localizedDescription, privacy: .public)")
            reply.text = String(localized: "Das sind die passendsten Stellen in deinen Notizen:", bundle: .module)
            reply.sources = Array(selectSources(from: result.passages).prefix(5))
            reply.notices.append(String(localized: "Apple Intelligence konnte keine Antwort formulieren.", bundle: .module))
            return reply
        }

        guard !outcome.sources.isEmpty else {
            reply.text = String(localized: "Dazu habe ich in deinen Notizen nichts gefunden.", bundle: .module)
            reply.notices.append(String(localized: "Die passendsten Notizen findest du unten.", bundle: .module))
            return reply
        }
        reply.text = outcome.answer.text
        if outcome.answer.isAnswerFound {
            let cited = Set(outcome.answer.citedSources)
            let shown = cited.isEmpty ? outcome.sources : outcome.sources.filter { cited.contains($0.number) }
            reply.sources = shown.map(Self.chatSource)
        } else {
            reply.notices.append(String(localized: "Die passendsten Notizen findest du unten.", bundle: .module))
        }

        let readable = CrossNoteAnswering.readableNotes(in: result).count
        let read = min(readable, CrossNoteAnswering.maximumNotes)
        if readable > read {
            reply.notices.append(String(localized: "Ich habe die \(read) passendsten von \(readable) Notizen ausgewertet.", bundle: .module))
        }
        if outcome.failedNotes > 0 {
            reply.notices.append(String(localized: "In \(outcome.failedNotes) von \(read) Notizen konnte Apple Intelligence nichts herauslesen; dort zählt die passendste Stelle.", bundle: .module))
        }
        if outcome.shortenedNotes > 0 {
            reply.notices.append(String(localized: "Aus \(outcome.shortenedNotes) von \(read) Notizen ist nicht jedes Detail in die Antwort eingeflossen, weil der Platz nicht reichte.", bundle: .module))
        }
        return reply
    }

    private static func chatSource(_ source: CrossNoteAnswering.NoteSource) -> ChatSource {
        let note = source.hit.note
        let passage = source.passage?.passage
        let text = passage?.text ?? source.text
        return ChatSource(
            number: source.number,
            noteID: note.id,
            noteTitle: note.title,
            noteDate: note.createdAt,
            labels: note.labels,
            noteKind: note.kind,
            start: passage?.start,
            excerpt: text.count > maximumSourceCharacters ? String(text.prefix(maximumSourceCharacters)) + " …" : text,
            isSummary: passage.map { $0.kind == .summary } ?? true
        )
    }

    nonisolated private static func append(_ notice: String, to message: inout ChatMessage) {
        message.notice = [message.notice, notice].compactMap { $0 }.joined(separator: " ")
    }

    /// Lets the language model answer from the sources and keeps only the sources it cited.
    /// Without an answer, the best passages are shown instead.
    private func answer(_ question: String, from sources: [ChatSource], history: [ChatTurn], now date: Date, into message: inout ChatMessage) async {
        do {
            let answer = try await assistant.answer(
                question: question,
                sources: sources.map {
                    AssistantSource(number: $0.number, noteTitle: $0.noteTitle, noteDate: $0.noteDate, labels: $0.labels, start: $0.start, text: $0.excerpt)
                },
                history: history,
                language: settings.transcription.language,
                now: date
            )
            message.text = answer.text
            if answer.isAnswerFound {
                let cited = answer.citedSources.compactMap { number in sources.first { $0.number == number } }
                message.sources = cited.isEmpty ? Array(sources.prefix(3)) : cited
            } else {
                message.notice = [message.notice, String(localized: "Die passendsten Notizen findest du unten.", bundle: .module)]
                    .compactMap { $0 }
                    .joined(separator: " ")
            }
        } catch is CancellationError {
            message.text = ""
        } catch {
            logger.error("Answering a question failed: \(error.localizedDescription, privacy: .public)")
            message.text = String(localized: "Das sind die passendsten Stellen in deinen Notizen:", bundle: .module)
            message.sources = Array(sources.prefix(5))
            message.notice = [message.notice, String(localized: "Apple Intelligence konnte keine Antwort formulieren.", bundle: .module)]
                .compactMap { $0 }
                .joined(separator: " ")
        }
    }

    /// Rules first; the language model adds synonyms, people and a time frame the rules missed.
    private func makePlan(for question: String, history: [ChatTurn], index: KnowledgeIndex, now: Date, useModel: Bool) async -> QueryPlan {
        var plan = RuleBasedQueryParser(now: now).plan(for: question, knownPersons: index.knownPersons, knownLabels: index.knownLabels)
        guard useModel else { return plan }
        do {
            let generated = try await assistant.plan(question: question, history: history, now: now)
            Self.merge(generated, into: &plan, now: now)
        } catch {
            logger.error("Planning the search failed: \(error.localizedDescription, privacy: .public)")
        }
        return plan
    }

    /// Internal for tests.
    nonisolated static func merge(_ generated: AssistantPlan, into plan: inout QueryPlan, now: Date, calendar: Calendar = .current) {
        // A label found by the rules is a filter, not a search term, also in the model's query.
        let labelWords = Set(plan.filters.labels.flatMap(TextAnalysis.normalizedWords(in:)))
        // A request for a summary keeps the rules' topic: the model would search for
        // "Meetings" again and find only notes that say the word.
        if !plan.wantsCollectionSummary {
            let query = RuleBasedQueryParser.removing(plan.filters.labels + RuleBasedQueryParser.spanningWords, from: generated.searchQuery)
            if !query.isEmpty {
                plan.searchText = query
            }
            plan.expansions = generated.relatedTerms.filter { !Set(TextAnalysis.normalizedWords(in: $0)).isSubset(of: labelWords) }
        }
        // Explicit time expressions found by the rules win; the model covers the rest.
        if plan.filters.dateRange == nil, generated.timeframe != .none,
           let range = generated.timeframe.dateRange(now: now, calendar: calendar) {
            plan.filters.dateRange = range
            plan.filterDescriptions.append(generated.timeframe.title)
        }
        let persons = generated.persons.filter { !Set(TextAnalysis.normalizedWords(in: $0)).isSubset(of: labelWords) }
        for person in persons where !plan.filters.persons.contains(where: { HybridRetriever.name($0, matches: person) }) {
            plan.filters.persons.append(person)
            plan.filterDescriptions.append(String(localized: "Person: \(person)", bundle: .module))
        }
        plan.wantsList = plan.wantsList || generated.wantsList
        plan.spansNotes = plan.spansNotes || generated.spansNotes
    }

    /// Numbered sources within the token budget, best first.
    private func selectSources(from hits: [PassageHit]) -> [ChatSource] {
        var sources: [ChatSource] = []
        var tokens = 0
        for hit in hits {
            let excerpt = hit.passage.text.count > Self.maximumSourceCharacters
                ? String(hit.passage.text.prefix(Self.maximumSourceCharacters)) + " …"
                : hit.passage.text
            let cost = excerpt.count / 3 + 30
            if !sources.isEmpty, tokens + cost > Self.sourceTokenBudget { break }
            tokens += cost
            sources.append(ChatSource(
                number: sources.count + 1,
                noteID: hit.note.id,
                noteTitle: hit.note.title,
                noteDate: hit.note.createdAt,
                labels: hit.note.labels,
                noteKind: hit.note.kind,
                start: hit.passage.start,
                excerpt: excerpt,
                isSummary: hit.passage.kind == .summary
            ))
            if sources.count == Self.maximumSources { break }
        }
        return sources
    }

    private static func unavailableNotice(_ availability: LanguageModelAvailability) -> String? {
        guard case .unavailable(let reason) = availability else { return nil }
        return String(localized: "\(reason) Ohne Apple Intelligence zeige ich die passenden Stellen statt einer formulierten Antwort.", bundle: .module)
    }
}
