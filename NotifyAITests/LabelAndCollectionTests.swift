//
//  LabelAndCollectionTests.swift
//  NotifyAITests
//
//  Labels: how they are written, stored, found in questions and used by search, summary and
//  export. Summaries across several notes: choosing the notes, making the collection,
//  summarizing it from the notes' summaries and listing their tasks once.
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
import SwiftData
import Synchronization
import Testing

/// Wednesday, 30 September 2026.
private let fixedNow = Date(timeIntervalSince1970: 1_790_762_400)

/// Store, queue, library, labels and collections with summaries that never use a real model.
@MainActor
private struct Services {
    let store: NoteStore
    let processing: ProcessingCoordinator
    let library: NoteLibrary
    let labels: NoteLabels
    let collections: NoteCollections

    init() throws {
        store = try NoteStore(locations: try StorageLocations.temporary(), inMemory: true)
        let engine = MockTranscriptionEngine(kind: .appleSpeech)
        processing = ProcessingCoordinator(
            store: store,
            settings: makeIsolatedSettings(),
            transcription: TranscriptionService(appleSpeech: engine, whisper: engine, parakeet: engine),
            summarization: SummarizationService(languageModel: MockSummarizer(), fallback: MockSummarizer(), availability: { _ in .available }),
            diarizer: SpeakerDiarizer()
        )
        library = NoteLibrary(store: store, processing: processing)
        labels = NoteLabels(store: store)
        collections = NoteCollections(store: store, processing: processing)
    }
}

@MainActor
private func makeServices() throws -> Services {
    try Services()
}

/// A finished note with a summary and tasks.
@MainActor
@discardableResult
private func insertNote(
    _ title: String,
    in store: NoteStore,
    daysAgo: Int = 1,
    labels: [String] = [],
    focus: RecordingFocus = .meeting,
    participants: [String] = [],
    overview: String = "Überblick",
    tasks: [ActionItem] = []
) throws -> Note {
    let created = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
    let note = Note(
        title: title, isTitleUserDefined: true, createdAt: created, kind: .recording, status: .ready,
        focus: focus, participants: participants, bodyText: overview
    )
    note.summary = NoteSummary(overview: overview, keyPoints: ["Punkt aus \(title)"], actionItems: tasks, source: .appleIntelligence)
    note.setLabels(labels)
    try store.insert(note)
    return note
}

// MARK: - Labels

@Suite("Labels")
@MainActor
struct LabelTests {
    @Test("Labels are trimmed, compared without case and accents, and stored as query keys")
    func normalization() {
        #expect(NoteLabel.normalized("  #Projekt   Atlas ") == "Projekt Atlas")
        #expect(NoteLabel.normalized(" # ") == nil)
        #expect(NoteLabel.normalized(String(repeating: "a", count: 60))?.count == NoteLabel.maximumLength)
        #expect(NoteLabel.key("Café  Müller") == NoteLabel.key("cafe muller"))
        #expect(NoteLabel.unique(["Samsung", "samsung", " ", "Atlas"]) == ["Samsung", "Atlas"])
        #expect(NoteLabel.keyList(of: ["Samsung", "Projekt Atlas"]) == "|samsung|projekt atlas|")
        #expect(NoteLabel.keyList(of: []).isEmpty)
    }

    @Test("Labels take the spelling they already have; renaming merges; deleting keeps the notes")
    func managing() throws {
        let services = try makeServices()
        let first = try insertNote("Weekly", in: services.store, labels: ["Samsung"])
        let second = try insertNote("Review", in: services.store)
        let revision = second.contentRevision

        #expect(services.labels.add("samsung", to: second))
        #expect(second.labels == ["Samsung"])
        #expect(second.labelKeys == "|samsung|")
        #expect(second.contentRevision > revision)
        #expect(!services.labels.add("  ", to: second))
        services.labels.add("Galaxy", to: second)
        #expect(services.labels.all().map(\.name) == ["Samsung", "Galaxy"])
        #expect(services.labels.all().first?.noteCount == 2)

        #expect(services.labels.rename("Galaxy", to: "SAMSUNG") == 1)
        #expect(second.labels == ["Samsung"])
        #expect(services.labels.all().map(\.name) == ["Samsung"])

        #expect(services.labels.remove("Samsung", from: first))
        #expect(first.labels.isEmpty && first.labelKeys.isEmpty)
        #expect(services.labels.delete("samsung") == 1)
        #expect(services.labels.all().isEmpty)
        #expect(try services.store.context.fetchCount(FetchDescriptor<Note>()) == 2)
    }

    @Test("The library lists the notes of a label and finds labels when searching")
    func library() throws {
        let store = try NoteStore(locations: try StorageLocations.temporary(), inMemory: true)
        try insertNote("Weekly", in: store, labels: ["Samsung", "Projekt Atlas"])
        try insertNote("Vorlesung", in: store)
        func titles(label: String?, search: String = "") throws -> [String] {
            let predicate = NoteQueries.library(filter: NoteListFilter(label: label), searchText: search)
            return try store.context.fetch(FetchDescriptor(predicate: predicate)).map(\.title)
        }
        #expect(try titles(label: "samsung") == ["Weekly"])
        #expect(try titles(label: "Projekt Atlas") == ["Weekly"])
        // "Atlas" alone is no label of the note.
        #expect(try titles(label: "Atlas").isEmpty)
        #expect(try titles(label: nil, search: "atlas") == ["Weekly"])
        #expect(try titles(label: nil).count == 2)
    }

    @Test("A recording draft's labels become the note's")
    func recordingDraft() throws {
        let store = try NoteStore(locations: try StorageLocations.temporary(), inMemory: true)
        var draft = RecordingController.Draft()
        draft.labels = "Samsung, , Projekt Atlas, samsung"
        let note = RecordingNoteWriter(store: store).makeNote(draft: draft, configuration: CaptureConfiguration(), language: .german)
        #expect(note.labels == ["Samsung", "Projekt Atlas"])
    }
}

// MARK: - Labels in questions and search

@Suite("Labels in questions")
struct LabelQueryTests {
    let parser = RuleBasedQueryParser(now: fixedNow)

    @Test("A label in the question is a filter, not a search term")
    func labelFilter() {
        let plan = parser.plan(for: "Samsung: Was wurde zum Budget entschieden?", knownPersons: ["Samsung"], knownLabels: ["Samsung", "Atlas"])
        #expect(plan.filters.labels == ["Samsung"])
        #expect(plan.filterDescriptions.contains("Label: Samsung"))
        #expect(plan.searchText == "Was wurde zum Budget entschieden?")
        // A label is no person, even if a name recognizer thought so.
        #expect(plan.filters.persons.isEmpty)
    }

    @Test("Labels of several words, the longest first; other words are kept")
    func multiWord() {
        let plan = parser.plan(for: "Was ist im Projekt Atlas noch offen?", knownPersons: [], knownLabels: ["Atlas", "Projekt Atlas"])
        #expect(plan.filters.labels == ["Projekt Atlas"])
        #expect(plan.searchText == "Was ist im noch offen?")
        #expect(parser.plan(for: "Wie lief die Atlasreise?", knownPersons: [], knownLabels: ["Atlas"]).filters.labels.isEmpty)
    }

    @Test("A request for a summary across notes keeps only its topic")
    func collectionRequest() {
        let plan = parser.plan(for: "Fasse alle Samsung-Meetings vom letzten Monat zum Budget zusammen", knownPersons: [], knownLabels: ["Samsung"])
        #expect(plan.wantsCollectionSummary)
        #expect(plan.filters.labels == ["Samsung"])
        #expect(plan.filters.dateRange != nil)
        #expect(TextAnalysis.terms(in: plan.searchText, languageCode: "de") == ["budget"])
        #expect(!parser.plan(for: "Was hat Anna zusammengefasst gesagt?", knownPersons: [], knownLabels: []).wantsCollectionSummary)
        #expect(!parser.plan(for: "Wie hoch ist das Budget?", knownPersons: [], knownLabels: []).wantsCollectionSummary)
    }

    @Test("Search keeps to the label's notes; without any, the label is searched as text")
    func retriever() {
        let samsung = IndexableNote(
            title: "Weekly",
            labels: ["Samsung"],
            bodyText: "Das Budget für die Kampagne liegt bei 12.000 Euro.",
            summary: NoteSummary(overview: "Budget festgelegt.", source: .appleIntelligence)
        )
        let other = IndexableNote(title: "Privat", bodyText: "Das Budget für den Urlaub liegt bei 2.000 Euro.")
        let builder = KnowledgeIndexBuilder(embedder: SentenceEmbedder())
        var index = KnowledgeIndex()
        for note in [samsung, other] {
            index.notes[note.id] = builder.entry(for: note)
        }
        #expect(index.knownLabels == ["Samsung"])
        #expect(index.notes[samsung.id]?.passages.contains { $0.kind == .summary && $0.text.contains("Labels: Samsung") } == true)

        let retriever = HybridRetriever(index: index, embedder: SentenceEmbedder())
        var filters = SearchFilters()
        filters.labels = ["samsung"]
        let result = retriever.search(SearchRequest(text: "Budget", filters: filters, languageCode: "de"))
        #expect(result.notes.map(\.note.id) == [samsung.id])
        #expect(result.notes.first?.reasons.contains("Label: Samsung") == true)

        filters.labels = ["Atlas"]
        let relaxed = retriever.search(SearchRequest(text: "Budget", filters: filters, languageCode: "de"))
        #expect(relaxed.relaxedLabels == ["Atlas"])
        #expect(relaxed.candidateCount == 2)
    }
}

/// Answers with whatever sources it gets, and remembers them.
private final class SourceRecordingAssistant: NoteAssistant {
    let sources = Mutex<[AssistantSource]>([])

    func plan(question: String, history: [ChatTurn], now: Date) async throws -> AssistantPlan {
        // Models tend to repeat the label in the query; the rules' filter still wins.
        AssistantPlan(searchQuery: question, relatedTerms: ["Samsung"], persons: ["Samsung"], timeframe: .none, wantsList: false)
    }

    func answer(question: String, sources: [AssistantSource], history: [ChatTurn], language: TranscriptionLanguage, now: Date) async throws -> AssistantAnswer {
        self.sources.withLock { $0 = sources }
        return AssistantAnswer(text: "Antwort [1].", citedSources: [1], isAnswerFound: true)
    }

    func findings(question: String, in note: AssistantSource, language: TranscriptionLanguage, now: Date) async throws -> NoteFindings {
        NoteFindings(points: [], isRelevant: false)
    }

    func answerAcrossNotes(
        question: String,
        notes: [AssistantSource],
        history: [ChatTurn],
        language: TranscriptionLanguage,
        now: Date
    ) async throws -> AssistantAnswer {
        AssistantAnswer(text: "", citedSources: [], isAnswerFound: false)
    }
}

@Suite("Labels and collections in the chat")
@MainActor
struct LabelChatTests {
    private func makeChat(assistant: SourceRecordingAssistant) throws -> NoteChatModel {
        let store = try NoteStore(locations: try StorageLocations.temporary(), inMemory: true)
        try insertNote("Samsung Weekly", in: store, labels: ["Samsung"], overview: "Das Budget der Kampagne liegt bei 12.000 Euro.")
        try insertNote("Samsung Review", in: store, daysAgo: 3, labels: ["Samsung"], overview: "Das Budget wurde auf 15.000 Euro erhöht.")
        try insertNote("Privat", in: store, overview: "Das Budget für den Urlaub liegt bei 2.000 Euro.")
        let knowledge = KnowledgeIndexService(store: store, embedder: SentenceEmbedder(), persistence: nil)
        return NoteChatModel(knowledge: knowledge, settings: makeIsolatedSettings(), assistant: assistant, availability: { _ in .available }, now: { .now })
    }

    @Test("A question with a label is answered from that label's notes only")
    func labeledQuestion() async throws {
        let assistant = SourceRecordingAssistant()
        let chat = try makeChat(assistant: assistant)
        let message = await chat.respond(to: "Samsung: Wie hoch ist das Budget?", history: [])
        #expect(message.filters.contains("Label: Samsung"))
        #expect(!message.filters.contains("Person: Samsung"))
        let titles = Set(assistant.sources.withLock { $0.map(\.noteTitle) })
        #expect(titles == ["Samsung Weekly", "Samsung Review"])
        #expect(assistant.sources.withLock { $0.allSatisfy { $0.labels == ["Samsung"] } })
    }

    @Test("Asking for a summary across notes offers exactly those notes")
    func summaryRequest() async throws {
        let assistant = SourceRecordingAssistant()
        let chat = try makeChat(assistant: assistant)
        let message = await chat.respond(to: "Fasse alle Samsung-Meetings zusammen", history: [])
        #expect(message.collectionNoteIDs.count == 2)
        #expect(message.sources.isEmpty)
        // No excerpt-based answer that would sound complete.
        #expect(assistant.sources.withLock { $0.isEmpty })
    }
}

// MARK: - Collections

@Suite("Summaries across several notes", .timeLimit(.minutes(1)))
@MainActor
struct CollectionTests {
    @Test("Candidates: finished notes with a summary, by period, label, person and template")
    func candidates() throws {
        let services = try makeServices()
        let store = services.store
        try insertNote("Weekly", in: store, daysAgo: 2, labels: ["Samsung"], participants: ["Anna Schmidt"])
        try insertNote("Review", in: store, daysAgo: 40, labels: ["Samsung"])
        try insertNote("Vorlesung", in: store, daysAgo: 5, focus: .lecture)
        let processing = try insertNote("Läuft", in: store)
        processing.status = .summarizing
        let collections = services.collections

        #expect(collections.candidates(matching: CollectionFilter()).map(\.title) == ["Weekly", "Vorlesung", "Review"])
        let month = Calendar.current.date(byAdding: .day, value: -30, to: .now)
        #expect(collections.candidates(matching: CollectionFilter(from: month)).map(\.title) == ["Weekly", "Vorlesung"])
        #expect(collections.candidates(matching: CollectionFilter(label: "samsung")).map(\.title) == ["Weekly", "Review"])
        #expect(collections.candidates(matching: CollectionFilter(person: "Anna")).map(\.title) == ["Weekly"])
        #expect(collections.candidates(matching: CollectionFilter(template: .focus(.lecture))).map(\.title) == ["Vorlesung"])
        #expect(collections.people(in: collections.candidates(matching: CollectionFilter())) == ["Anna Schmidt"])
    }

    @Test("A collection remembers its notes, oldest first, and their shared labels; it is queued")
    func create() throws {
        let services = try makeServices()
        let store = services.store
        let older = try insertNote("Review", in: store, daysAgo: 9, labels: ["Samsung", "Atlas"])
        let newer = try insertNote("Weekly", in: store, daysAgo: 2, labels: ["Samsung"])
        let collections = services.collections

        #expect(throws: CollectionError.tooFewNotes) { try collections.create(from: [newer], title: "X") }
        #expect(throws: CollectionError.emptyTitle) { try collections.create(from: [newer, older], title: " ") }
        #expect(collections.suggestedTitle(for: [newer, older]).hasPrefix("Samsung · "))

        let collection = try collections.create(from: [newer, older], title: "Samsung Oktober")
        #expect(collection.kind == .collection)
        #expect(collection.sourceNoteIDs == [older.id, newer.id])
        #expect(collection.labels == ["Samsung"])
        #expect(collection.bodyText.contains("Note 1 of 2: \"Review\""))
        #expect(collection.bodyText.contains("Note 2 of 2: \"Weekly\""))
        #expect(collection.status == .queued || collection.status.isProcessing)
        #expect(collections.sources(of: collection).map(\.title) == ["Review", "Weekly"])
        // Collections are no candidates for further collections.
        #expect(!collections.candidates(matching: CollectionFilter()).contains { $0.id == collection.id })
    }

    @Test("Tasks of the notes appear once; ticking one off ticks it off in every note")
    func tasks() throws {
        let services = try makeServices()
        let store = services.store
        let first = try insertNote("Weekly", in: store, daysAgo: 9, tasks: [
            ActionItem(task: "Angebot an Frau Berger schicken", owner: "Anna"),
            ActionItem(task: "Raum buchen"),
        ])
        let second = try insertNote("Review", in: store, daysAgo: 2, tasks: [
            ActionItem(task: "Das Angebot an Frau Berger schicken", due: "Freitag"),
            ActionItem(task: "Catering bestellen", isDone: true),
        ])
        let collection = try services.collections.create(from: [first, second], title: "Alles")

        let tasks = services.collections.tasks(of: collection)
        #expect(tasks.map(\.item.task) == ["Angebot an Frau Berger schicken", "Raum buchen", "Catering bestellen"])
        let offer = try #require(tasks.first)
        #expect(offer.taskIDs.count == 2)
        #expect(offer.noteTitles == ["Weekly", "Review"])
        #expect(offer.item.owner == "Anna" && offer.item.due == "Freitag")

        services.collections.setDone(offer, true)
        #expect(first.sortedTasks.first?.isDone == true)
        #expect(second.sortedTasks.first?.isDone == true)
        // Done everywhere: it moves behind the open ones.
        #expect(services.collections.tasks(of: collection).map(\.item.task) == ["Raum buchen", "Angebot an Frau Berger schicken", "Catering bestellen"])
    }

    @Test("The queue summarizes a collection from the notes' summaries, without tasks of its own")
    func processing() async throws {
        let services = try makeServices()
        let store = services.store
        let first = try insertNote("Weekly", in: store, daysAgo: 9, overview: "Das Budget liegt bei 12.000 Euro.", tasks: [
            ActionItem(task: "Budget prüfen"),
        ])
        let second = try insertNote("Review", in: store, daysAgo: 2, overview: "Das Budget wurde erhöht.")
        let collection = try services.collections.create(from: [first, second], title: "Budget")
        await waitUntil { collection.status == .ready || collection.status == .failed }

        #expect(collection.status == .ready)
        let summary = try #require(collection.summary)
        #expect(!summary.overview.isEmpty)
        #expect(summary.actionItems.isEmpty)
        #expect(collection.tasks.isEmpty)
        #expect(collection.title == "Budget")

        // Summarizing again reads the notes as they are now; a deleted note is left out.
        services.library.delete(second)
        services.processing.enqueue(.resummarize(collection.id))
        await waitUntil { !collection.status.isProcessing }
        #expect(collection.status == .ready)
        #expect(collection.bodyText.contains("Weekly") && !collection.bodyText.contains("Review"))

        services.library.delete(first)
        services.processing.enqueue(.resummarize(collection.id))
        await waitUntil { !collection.status.isProcessing }
        #expect(collection.status == .failed)
        #expect(collection.statusMessage == ProcessingError.missingSourceNotes.localizedDescription)
    }

    @Test("Apple Intelligence gets the notes as summaries, oldest first, and is told what a collection is")
    func prompt() async throws {
        let responder = TemplateResponder()
        let service = SummarizationService(
            languageModel: FoundationModelSummarizer(responder: responder, measure: TextChunker.estimatedTokens),
            fallback: ExtractiveSummarizer(),
            availability: { _ in .available }
        )
        let review = NoteSummary(overview: "Das Budget wurde erhöht.", actionItems: [ActionItem(task: "Budget prüfen")], source: .appleIntelligence)
        let weekly = NoteSummary(overview: "Der Kunde wünscht einen Relaunch.", source: .appleIntelligence)
        let sources = [
            CollectionSource(title: "Review", createdAt: fixedNow.addingTimeInterval(-86_400 * 9), templateName: "Meeting", labels: ["Samsung"], summary: review),
            CollectionSource(title: "Weekly", createdAt: fixedNow, summary: weekly),
        ]
        var request = SummaryRequest(text: CollectionSource.text(of: sources), language: .german, focus: .general, kind: .collection, markedPassages: [])
        request.labels = ["Samsung"]
        let summary = try await service.summarizeCollection(request, sources: sources) { _ in }

        // The responder's summary has a task; a collection's tasks come from its notes instead.
        #expect(summary.actionItems.isEmpty)
        let instructions = try #require(responder.instructions.last)
        #expect(instructions.contains("summaries of several of the user's notes"))
        #expect(instructions.contains("Leave the list of tasks empty"))
        #expect(instructions.contains("labeled this content with: Samsung"))
        #expect(request.text.contains("Note 1 of 2: \"Review\""))
        #expect(request.text.contains("labels: Samsung"))
        #expect(request.text.contains("Task: Budget prüfen"))
    }

    @Test("Without Apple Intelligence the notes' summaries are merged and the summary says why")
    func withoutModel() async throws {
        let service = SummarizationService(
            languageModel: MockSummarizer(),
            fallback: ExtractiveSummarizer(),
            availability: { _ in .unavailable(reason: "Nicht verfügbar.") }
        )
        func summary(_ overview: String, point: String) -> NoteSummary {
            NoteSummary(overview: overview, keyPoints: [point], decisions: ["Entscheidung"], source: .appleIntelligence)
        }
        let sources = [
            CollectionSource(title: "A", createdAt: fixedNow, summary: summary("Erstens.", point: "Punkt A")),
            CollectionSource(title: "B", createdAt: fixedNow, summary: summary("Zweitens.", point: "Punkt B")),
        ]
        let request = SummaryRequest(text: CollectionSource.text(of: sources), language: .german, focus: .general, kind: .collection, markedPassages: [])
        let summary = try await service.summarizeCollection(request, sources: sources) { _ in }
        #expect(summary.source == .extractive)
        #expect(summary.fallbackReason == "Nicht verfügbar.")
        #expect(summary.keyPoints == ["Punkt A", "Punkt B"])
        #expect(summary.decisions == ["Entscheidung"])
    }

    @Test("Export: the notes instead of the source text, their tasks once, and the labels")
    func export() throws {
        let services = try makeServices()
        let store = services.store
        let first = try insertNote("Weekly", in: store, daysAgo: 9, labels: ["Samsung"], tasks: [ActionItem(task: "Budget prüfen")])
        let second = try insertNote("Review", in: store, daysAgo: 2, labels: ["Samsung"], tasks: [ActionItem(task: "Budget prüfen")])
        let collection = try services.collections.create(from: [first, second], title: "Samsung")
        collection.summary = NoteSummary(overview: "Zwei Meetings zum Budget.", source: .appleIntelligence)

        let snapshot = MarkdownExporter.NoteSnapshot(note: collection, segments: [])
        #expect(snapshot.bodyText.isEmpty)
        #expect(snapshot.sources.count == 2 && snapshot.sources[0].hasPrefix("Weekly · "))
        #expect(snapshot.summary?.actionItems.map(\.task) == ["Budget prüfen"])
        let markdown = MarkdownExporter().markdown(for: snapshot)
        #expect(markdown.contains("Labels: Samsung"))
        #expect(markdown.contains("## Zusammengefasste Notizen"))
        #expect(!markdown.contains("Note 1 of 2"))
    }
}

// MARK: - Migration

@Suite("Schema migration to V7")
@MainActor
struct MigrationToV7Tests {
    @Test("V6 notes open with V7 without labels or source notes")
    func fromV6() throws {
        let locations = try StorageLocations.temporary()
        let noteID = UUID()
        do {
            let schema = Schema(versionedSchema: NotifyAISchemaV6.self)
            let configuration = ModelConfiguration(schema: schema, url: locations.databaseURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: configuration)
            let context = ModelContext(container)
            context.insert(NotifyAISchemaV6.Note(id: noteID, title: "Weekly", isTitleUserDefined: true, kind: .recording, status: .ready))
            try context.save()
        }
        let store = try NoteStore(locations: locations)
        let note = try #require(store.note(id: noteID))
        #expect(note.labels.isEmpty && note.labelKeys.isEmpty && note.sourceNoteIDs.isEmpty)
        note.setLabels(["Samsung"])
        note.sourceNoteIDs = [UUID()]
        try store.save()
        #expect(store.note(id: noteID)?.labelKeys == "|samsung|")
    }
}
