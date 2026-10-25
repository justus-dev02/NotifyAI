//
//  CrossNoteAnsweringTests.swift
//  NotifyAITests
//
//  Questions whose answer is spread over several notes: every matching note is read on its
//  own, and the findings are combined.
//

import Foundation
@testable import NotifyAI
@testable import NotifyAIAudio
@testable import NotifyAICore
@testable import NotifyAIExport
@testable import NotifyAIIntegrations
@testable import NotifyAIKnowledge
@testable import NotifyAILibrary
@testable import NotifyAINeuralModels
@testable import NotifyAIPersistence
@testable import NotifyAIProcessing
@testable import NotifyAIRecording
@testable import NotifyAIServices
@testable import NotifyAISettings
@testable import NotifyAISpeakers
@testable import NotifyAISummarization
@testable import NotifyAISupport
@testable import NotifyAITranscription
import Synchronization
import Testing

/// Reads notes as configured per title and remembers every request.
private final class CrossNoteAssistant: NoteAssistant {
    struct Reply {
        var points: [String] = []
        var isRelevant = true
        var fails = false
    }

    struct Failure: Error {}

    let replies: [String: Reply]
    let read = Mutex<[String]>([])
    let combined = Mutex<[AssistantSource]>([])

    init(replies: [String: Reply] = [:]) {
        self.replies = replies
    }

    func plan(question: String, history: [ChatTurn], now: Date) async throws -> AssistantPlan {
        AssistantPlan(searchQuery: question, relatedTerms: [], persons: [], timeframe: .none, wantsList: false)
    }

    func answer(question: String, sources: [AssistantSource], history: [ChatTurn], language: TranscriptionLanguage, now: Date) async throws -> AssistantAnswer {
        Issue.record("A question across notes must not be answered from single passages")
        return AssistantAnswer(text: "", citedSources: [], isAnswerFound: false)
    }

    func findings(question: String, in note: AssistantSource, language: TranscriptionLanguage, now: Date) async throws -> NoteFindings {
        read.withLock { $0.append(note.noteTitle) }
        let reply = replies[note.noteTitle] ?? Reply()
        if reply.fails { throw Failure() }
        return NoteFindings(points: reply.points, isRelevant: reply.isRelevant)
    }

    func answerAcrossNotes(
        question: String,
        notes: [AssistantSource],
        history: [ChatTurn],
        language: TranscriptionLanguage,
        now: Date
    ) async throws -> AssistantAnswer {
        combined.withLock { $0 = notes }
        let text = notes.map { "\($0.noteTitle) [\($0.number)]" }.joined(separator: ", ")
        return FoundationModelNoteAssistant.validated(answer: text, usedSources: [], answerFound: true, sourceCount: notes.count)
    }
}

@Suite("Answers across notes")
@MainActor
struct CrossNoteAnsweringTests {
    private let index = Fixture.index()

    private func search(_ text: String) -> SearchResult {
        HybridRetriever(index: index, embedder: SentenceEmbedder())
            .search(SearchRequest(text: text, languageCode: "de"), passageLimit: CrossNoteAnswering.passageLimit)
    }

    /// An answering that has to read the notes one by one: their contexts do not fit together.
    private func reading(_ result: SearchResult, assistant: CrossNoteAssistant) -> CrossNoteAnswering {
        var answering = CrossNoteAnswering(assistant: assistant, language: .german)
        let contexts = CrossNoteAnswering.readableNotes(in: result).map { answering.context(of: $0.note, passages: result.passages) }
        answering.sourceCharacters = contexts.reduce(0) { $0 + $1.count } - 1
        return answering
    }

    @Test("Notes that fit are combined as they are, oldest first, each with its summary and passages")
    func direct() async throws {
        let result = search("Herbstkampagne Budget")
        let assistant = CrossNoteAssistant()
        var steps: [CrossNoteAnswering.Step] = []
        let outcome = try await CrossNoteAnswering(assistant: assistant, language: .german)
            .answer("Herbstkampagne Budget", from: result, history: [], now: Fixture.now) { steps.append($0) }

        #expect(assistant.read.withLock { $0.isEmpty })
        #expect(outcome.sources.map(\.hit.note.title) == ["Marketing-Runde", "Kampagne Abstimmung"])
        #expect(outcome.sources.map(\.number) == [1, 2])
        let first = try #require(assistant.combined.withLock { $0.first })
        #expect(first.text.contains("Das Budget der Herbstkampagne beträgt 12.000 Euro."))
        #expect(first.text.contains("Anna sagt, das Budget für die Kampagne liegt bei 12.000 Euro."))
        #expect(outcome.answer.text == "Marketing-Runde [1], Kampagne Abstimmung [2]")
        #expect(outcome.answer.citedSources == [1, 2])
        #expect(steps == [.combining(notes: 2)])
    }

    @Test("Long notes are read one by one; notes without anything to say and invented points are left out")
    func mapReduce() async throws {
        let result = search("Herbstkampagne Budget")
        let assistant = CrossNoteAssistant(replies: [
            "Marketing-Runde": .init(points: ["Das Budget der Herbstkampagne beträgt 12.000 Euro.", "Quantenphysik auf dem Mars"]),
            "Kampagne Abstimmung": .init(isRelevant: false),
        ])
        var steps: [CrossNoteAnswering.Step] = []
        let outcome = try await reading(result, assistant: assistant)
            .answer("Herbstkampagne Budget", from: result, history: [], now: Fixture.now) { steps.append($0) }

        #expect(assistant.read.withLock { $0 } == ["Marketing-Runde", "Kampagne Abstimmung"])
        #expect(outcome.sources.map(\.hit.note.title) == ["Marketing-Runde"])
        #expect(outcome.sources.first?.text == "- Das Budget der Herbstkampagne beträgt 12.000 Euro.")
        #expect(steps == [.reading(note: 1, count: 2), .reading(note: 2, count: 2), .combining(notes: 1)])
        #expect(outcome.failedNotes == 0)
        #expect(outcome.shortenedNotes == 0)
    }

    @Test("A note the model fails on contributes its best passage")
    func failure() async throws {
        let result = search("Herbstkampagne Budget")
        let assistant = CrossNoteAssistant(replies: [
            "Marketing-Runde": .init(points: ["Das Budget der Herbstkampagne beträgt 12.000 Euro."]),
            "Kampagne Abstimmung": .init(fails: true),
        ])
        let outcome = try await reading(result, assistant: assistant)
            .answer("Herbstkampagne Budget", from: result, history: [], now: Fixture.now) { _ in }

        #expect(outcome.failedNotes == 1)
        let fallback = try #require(outcome.sources.first { $0.hit.note.title == "Kampagne Abstimmung" })
        #expect(fallback.text == "- " + (fallback.passage?.passage.text ?? "missing"))
    }

    @Test("Findings that do not fit are cut from the least relevant note first")
    func fitting() async throws {
        let result = search("Herbstkampagne Budget")
        let long = (1...5).map { "Punkt \($0): Das Budget der Herbstkampagne " + String(repeating: "und die Agentur ", count: 20) }
        let assistant = CrossNoteAssistant(replies: ["Marketing-Runde": .init(points: long), "Kampagne Abstimmung": .init(points: long)])
        let answering = reading(result, assistant: assistant)
        let outcome = try await answering.answer("Herbstkampagne Budget", from: result, history: [], now: Fixture.now) { _ in }

        #expect(outcome.shortenedNotes >= 1)
        #expect(outcome.sources.reduce(0) { $0 + $1.text.count } <= answering.sourceCharacters)
        // The best note of the search keeps more of its findings.
        let lines = Dictionary(uniqueKeysWithValues: outcome.sources.map { ($0.hit.note.title, $0.text.split(separator: "\n").count) })
        let best = try #require(result.notes.first?.note.title)
        #expect(lines.values.allSatisfy { $0 >= 1 })
        #expect(lines[best] == lines.values.max())
    }

    @Test("Summaries across notes are not read again")
    func collectionsAreSkipped() {
        let summary = NoteSummary(overview: "Herbstkampagne Budget", source: .appleIntelligence)
        let collection = IndexableNote(title: "Samsung gesamt", kind: .collection, bodyText: "", summary: summary)
        let index = Fixture.index([Fixture.budgetMeeting, Fixture.followUp, collection])
        let result = HybridRetriever(index: index, embedder: SentenceEmbedder()).search(SearchRequest(text: "Herbstkampagne Budget", languageCode: "de"))
        #expect(result.notes.contains { $0.note.kind == .collection })
        #expect(!CrossNoteAnswering.readableNotes(in: result).contains { $0.note.kind == .collection })
    }

    @Test("In the chat, a question about several meetings reads every matching note, oldest first")
    func chat() async throws {
        let store = try NoteStore(locations: try StorageLocations.temporary(), inMemory: true)
        let notes = [
            ("Samsung Weekly", 1, "Das Budget der Kampagne liegt bei 12.000 Euro."),
            ("Samsung Review", 3, "Das Budget wurde auf 15.000 Euro erhöht."),
            ("Privat", 2, "Das Budget für den Urlaub liegt bei 2.000 Euro."),
        ]
        for (title, daysAgo, overview) in notes {
            let note = Note(
                title: title, isTitleUserDefined: true, createdAt: Fixture.date(daysAgo: daysAgo), kind: .recording, status: .ready,
                focus: .meeting, bodyText: overview
            )
            note.summary = NoteSummary(overview: overview, source: .appleIntelligence)
            note.setLabels(title == "Privat" ? [] : ["Samsung"])
            try store.insert(note)
        }
        let assistant = CrossNoteAssistant()
        let chat = NoteChatModel(
            knowledge: KnowledgeIndexService(store: store, embedder: SentenceEmbedder(), persistence: nil),
            settings: makeIsolatedSettings(),
            assistant: assistant,
            availability: { _ in .available },
            now: { Fixture.now }
        )
        let message = await chat.respond(to: "Samsung: Wie hoch war das Budget bisher?", history: [])

        #expect(assistant.combined.withLock { $0.map(\.noteTitle) } == ["Samsung Review", "Samsung Weekly"])
        #expect(message.text == "Samsung Review [1], Samsung Weekly [2]")
        // One card per note, showing the note's own words.
        #expect(message.sources.map(\.noteTitle) == ["Samsung Review", "Samsung Weekly"])
        #expect(message.sources.first?.excerpt.contains("15.000 Euro") == true)
        #expect(message.notice == nil)
    }
}
