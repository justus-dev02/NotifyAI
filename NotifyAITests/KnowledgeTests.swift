//
//  KnowledgeTests.swift
//  NotifyAITests
//

import Foundation
@testable import NotifyAI
import NotifyAICore
import Testing

// MARK: - Fixtures

private enum Fixture {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "de_DE")
        calendar.firstWeekday = 2
        return calendar
    }()

    /// Wednesday, 30 September 2026, 12:00.
    static let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 12))!

    static func date(daysAgo: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: now)!
    }

    static func segments(_ texts: [String], speaker: String? = nil, step: TimeInterval = 10) -> [TranscriptSegment] {
        texts.enumerated().map { index, text in
            TranscriptSegment(start: Double(index) * step, end: Double(index) * step + step - 1, text: text, speaker: speaker)
        }
    }

    static let budgetMeeting = IndexableNote(
        title: "Marketing-Runde",
        createdAt: date(daysAgo: 8),
        focus: .meeting,
        participants: ["Anna Schmidt"],
        bodyText: "",
        segments: segments([
            "Wir sprechen heute über das Budget der Herbstkampagne.",
            "Anna sagt, das Budget für die Kampagne liegt bei 12.000 Euro.",
            "Die Anzeigen auf Instagram starten am 15. Oktober.",
            "Ben übernimmt die Abstimmung mit der Agentur.",
        ]),
        summary: NoteSummary(
            overview: "Budget der Herbstkampagne festgelegt.",
            decisions: ["Das Budget der Herbstkampagne beträgt 12.000 Euro."],
            source: .appleIntelligence,
            keywords: ["Herbstkampagne", "Budget"]
        )
    )

    static let lecture = IndexableNote(
        title: "Vorlesung Statistik",
        createdAt: date(daysAgo: 1),
        focus: .lecture,
        bodyText: "",
        segments: segments([
            "Die Varianz beschreibt die Streuung einer Zufallsvariable.",
            "Die Standardabweichung ist die Wurzel der Varianz.",
            "In der Klausur kommt die Normalverteilung dran.",
        ]),
        summary: NoteSummary(overview: "Varianz und Standardabweichung.", source: .appleIntelligence, keywords: ["Varianz", "Normalverteilung"])
    )

    static let followUp = IndexableNote(
        title: "Kampagne Abstimmung",
        createdAt: date(daysAgo: 6),
        participants: ["Anna Schmidt"],
        bodyText: "",
        segments: segments([
            "Anna berichtet, dass die Herbstkampagne im Budget bleibt.",
            "Die Agentur liefert die Motive bis Freitag.",
        ]),
        summary: NoteSummary(overview: "Stand der Herbstkampagne.", source: .appleIntelligence, keywords: ["Herbstkampagne", "Agentur"])
    )

    static func index(_ notes: [IndexableNote] = [budgetMeeting, lecture, followUp]) -> KnowledgeIndex {
        let builder = KnowledgeIndexBuilder(embedder: SentenceEmbedder())
        var index = KnowledgeIndex()
        for note in notes {
            index.notes[note.id] = builder.entry(for: note)
        }
        return index
    }
}

// MARK: - Text analysis

@Suite("Text analysis")
struct TextAnalysisTests {
    @Test("Search terms ignore case, accents, stop words and plural endings")
    func terms() {
        #expect(TextAnalysis.terms(in: "Die Budgets für das Marketing", languageCode: "de") == ["budget", "marketing"])
        #expect(TextAnalysis.terms(in: "Überprüfung", languageCode: "de") == TextAnalysis.terms(in: "uberprufung", languageCode: "de"))
        #expect(TextAnalysis.fold("Müller") == "muller")
    }

    @Test("Keywords are the recurring nouns, not filler words")
    func keywords() {
        let text = "Das Budget ist knapp. Wir prüfen das Budget nochmal. Das Budget für die Kampagne. Die Kampagne startet im Oktober. Ähm, genau."
        let keywords = TextAnalysis.keywords(in: text, languageCode: "de", limit: 2)
        #expect(keywords.first == "Budget")
        #expect(keywords.contains("Kampagne"))
    }

    @Test("Named entities are recognized")
    func entities() {
        let entities = TextAnalysis.entities(in: "Tim Cook visited Berlin to meet engineers from Siemens. Tim Cook liked Berlin.")
        #expect(entities.persons.contains("Tim Cook"))
        #expect(entities.places.contains("Berlin"))
    }

    @Test("Speaker labels are not names")
    func speakerLabels() {
        #expect(TextAnalysis.isSpeakerLabel("Ich"))
        #expect(TextAnalysis.isSpeakerLabel("Sprecher 2"))
        #expect(!TextAnalysis.isSpeakerLabel("Anna"))
    }
}

// MARK: - Index and search

@Suite("Search index and hybrid retrieval")
struct RetrievalTests {
    @Test("Transcripts become overlapping passages with positions, plus a summary passage")
    func passages() {
        let entry = KnowledgeIndexBuilder(embedder: SentenceEmbedder()).entry(for: Fixture.budgetMeeting)
        let transcript = entry.passages.filter { $0.kind == .transcript }
        #expect(!transcript.isEmpty)
        #expect(transcript.first?.start == 0)
        #expect(entry.passages.contains { $0.kind == .summary && $0.text.contains("12.000 Euro") })
        #expect(entry.persons.contains("Anna Schmidt"))
        #expect(entry.keywords.contains("Herbstkampagne"))
    }

    @Test("Full-text search finds the right note first")
    func lexicalSearch() {
        let retriever = HybridRetriever(index: Fixture.index(), embedder: SentenceEmbedder())
        let result = retriever.search(SearchRequest(text: "Standardabweichung Varianz", languageCode: "de"))
        #expect(result.notes.first?.note.title == "Vorlesung Statistik")
        #expect(result.passages.first?.note.title == "Vorlesung Statistik")
    }

    @Test("Filters restrict the candidates")
    func dateFilter() {
        let retriever = HybridRetriever(index: Fixture.index(), embedder: SentenceEmbedder())
        var filters = SearchFilters()
        // Last week is Monday 21 to Sunday 27 September: both campaign notes, not the lecture.
        filters.dateRange = Timeframe.lastWeek.dateRange(now: Fixture.now, calendar: Fixture.calendar)
        let result = retriever.search(SearchRequest(text: "Budget", filters: filters, languageCode: "de"))
        #expect(result.candidateCount == 2)
        #expect(Set(result.notes.map(\.note.title)) == ["Marketing-Runde", "Kampagne Abstimmung"])

        filters.dateRange = Timeframe.yesterday.dateRange(now: Fixture.now, calendar: Fixture.calendar)
        let yesterday = retriever.search(SearchRequest(text: "Varianz", filters: filters, languageCode: "de"))
        #expect(yesterday.notes.map(\.note.title) == ["Vorlesung Statistik"])
    }

    @Test("An unrelated question matches no note")
    func noMatch() {
        let retriever = HybridRetriever(index: Fixture.index(), embedder: SentenceEmbedder())
        let result = retriever.search(SearchRequest(text: "Rezept Pfannkuchen Zucker", languageCode: "de"))
        #expect(result.notes.isEmpty)
    }

    @Test("A person filter without matches is relaxed and reported")
    func relaxedPerson() {
        let retriever = HybridRetriever(index: Fixture.index(), embedder: SentenceEmbedder())
        var filters = SearchFilters()
        filters.persons = ["Clara"]
        let result = retriever.search(SearchRequest(text: "Budget", filters: filters, languageCode: "de"))
        #expect(result.relaxedPersons == ["Clara"])
        #expect(!result.notes.isEmpty)
    }

    @Test("A first name matches the full name")
    func personFilter() {
        let retriever = HybridRetriever(index: Fixture.index(), embedder: SentenceEmbedder())
        var filters = SearchFilters()
        filters.persons = ["Anna"]
        let result = retriever.search(SearchRequest(text: "Kampagne", filters: filters, languageCode: "de"))
        #expect(result.relaxedPersons.isEmpty)
        #expect(Set(result.notes.map(\.note.title)) == ["Marketing-Runde", "Kampagne Abstimmung"])
        #expect(result.notes.first?.reasons.contains { $0.hasPrefix("Person:") } == true)
    }

    @Test("A request with only filters lists the notes, newest first")
    func listing() {
        let retriever = HybridRetriever(index: Fixture.index(), embedder: SentenceEmbedder())
        let result = retriever.search(SearchRequest(text: "", languageCode: "de"))
        #expect(result.notes.map(\.note.title) == ["Vorlesung Statistik", "Kampagne Abstimmung", "Marketing-Runde"])
    }

    @Test("Semantic search finds a passage with different words", .enabled(if: SentenceEmbedder().supports(languageCode: "de")))
    func semanticSearch() {
        let retriever = HybridRetriever(index: Fixture.index(), embedder: SentenceEmbedder())
        let result = retriever.search(SearchRequest(text: "Wie viel Geld steht für die Werbung zur Verfügung?", languageCode: "de"))
        #expect(result.passages.prefix(3).contains { $0.note.title == "Marketing-Runde" || $0.note.title == "Kampagne Abstimmung" })
    }
}

// MARK: - Related notes

@Suite("Related notes")
struct RelatedNotesTests {
    @Test("Notes with the same person and a rare shared topic are related")
    func related() {
        let index = Fixture.index()
        let related = RelatedNotesFinder(index: index).related(to: Fixture.budgetMeeting.id)
        let first = related.first
        #expect(first?.note.title == "Kampagne Abstimmung")
        #expect(first?.reasons.contains(.person("Anna Schmidt")) == true)
        #expect(first?.reasons.contains(.topic("Herbstkampagne")) == true)
        #expect(!related.contains { $0.note.title == "Vorlesung Statistik" })
    }
}

// MARK: - Query understanding

@Suite("Understanding questions")
struct QueryPlannerTests {
    private let parser = RuleBasedQueryParser(now: Fixture.now, calendar: Fixture.calendar)

    @Test("Time expressions and known people become filters")
    func personAndTime() {
        let plan = parser.plan(for: "Was hat Anna letzte Woche zum Budget gesagt?", knownPersons: ["Anna Schmidt", "Ben"])
        #expect(plan.filters.persons == ["Anna"])
        #expect(plan.filters.dateRange == Timeframe.lastWeek.dateRange(now: Fixture.now, calendar: Fixture.calendar))
        #expect(plan.filterDescriptions.contains("Letzte Woche"))
        #expect(!plan.searchText.localizedCaseInsensitiveContains("letzte Woche"))
    }

    @Test("Months refer to the most recent one")
    func month() {
        let march = parser.plan(for: "Notizen im März", knownPersons: [])
        #expect(Fixture.calendar.component(.year, from: march.filters.dateRange!.start) == 2026)
        let november = parser.plan(for: "Was war im November?", knownPersons: [])
        #expect(Fixture.calendar.component(.year, from: november.filters.dateRange!.start) == 2025)
    }

    @Test("The last N days")
    func lastDays() {
        let plan = parser.plan(for: "Aufnahmen der letzten 7 Tage", knownPersons: [])
        let range = plan.filters.dateRange!
        #expect(range.end == Fixture.now)
        #expect(plan.filters.kinds == [.recording])
    }

    @Test("Listing requests are recognized")
    func listing() {
        #expect(parser.plan(for: "Zeig mir alle Meetings", knownPersons: []).wantsList)
        #expect(!parser.plan(for: "Was wurde im Meeting entschieden?", knownPersons: []).wantsList)
    }

    @Test("The language model adds what the rules missed; rules win for explicit dates")
    func merge() {
        var plan = parser.plan(for: "Was hat sie gestern gesagt?", knownPersons: [])
        let generated = AssistantPlan(searchQuery: "Aussagen Anna", relatedTerms: ["Meinung"], persons: ["Anna"], timeframe: .lastMonth, wantsList: false)
        NoteChatModel.merge(generated, into: &plan, now: Fixture.now, calendar: Fixture.calendar)
        #expect(plan.searchText == "Aussagen Anna")
        #expect(plan.expansions == ["Meinung"])
        #expect(plan.filters.persons == ["Anna"])
        #expect(plan.filters.dateRange == Timeframe.yesterday.dateRange(now: Fixture.now, calendar: Fixture.calendar))
    }
}

// MARK: - Answers, titles, evidence

@Suite("Answers, titles and evidence")
struct AnswerAndTitleTests {
    @Test("Citations of sources that do not exist are removed")
    func citations() {
        let answer = FoundationModelNoteAssistant.validated(
            answer: "Das Budget beträgt 12.000 Euro [1]. Start ist im Oktober [7][2].",
            usedSources: [2, 9],
            answerFound: true,
            sourceCount: 3
        )
        #expect(answer.text == "Das Budget beträgt 12.000 Euro [1]. Start ist im Oktober [2].")
        #expect(answer.citedSources == [1, 2])
    }

    @Test("Automatic titles: keywords and the recording date")
    func automaticTitle() {
        let locale = Locale(identifier: "de_DE")
        let date = Fixture.now
        let datePart = date.formatted(Date.FormatStyle(locale: locale).day().month(.abbreviated).year())
        #expect(AutomaticTitle.make(keywords: ["budget", "Website-Relaunch", "Budget"], date: date, locale: locale) == "Budget, Website-Relaunch – \(datePart)")
        #expect(AutomaticTitle.make(keywords: [], date: date, locale: locale) == "Aufnahme – \(datePart)")
        #expect(datePart.contains("2026"))
    }

    @Test("Title keywords prefer the summary, then its topics, then the transcript")
    func titleKeywords() {
        let withKeywords = NoteSummary(overview: "", topics: [SummaryTopic(title: "Thema", points: [])], source: .extractive, keywords: ["Budget"])
        #expect(AutomaticTitle.keywords(summary: withKeywords, transcriptText: "", languageCode: "de") == ["Budget"])
        let withTopics = NoteSummary(overview: "", topics: [SummaryTopic(title: "Umzug", points: [])], source: .extractive)
        #expect(AutomaticTitle.keywords(summary: withTopics, transcriptText: "", languageCode: "de") == ["Umzug"])
    }

    @Test("Summary items link to the supporting transcript position")
    func evidence() {
        let segments = Fixture.segments([
            "Guten Morgen zusammen.",
            "Das Budget für die Kampagne liegt bei 12.000 Euro.",
            "Ben übernimmt die Abstimmung mit der Agentur.",
            "Das Wetter ist schön.",
        ])
        let summary = NoteSummary(
            overview: "",
            decisions: ["Budget der Kampagne: 12.000 Euro"],
            actionItems: [ActionItem(task: "Abstimmung mit der Agentur", owner: "Ben")],
            openQuestions: ["Welche Farbe hat das Logo?"],
            source: .appleIntelligence
        )
        let times = SummaryEvidenceLinker(embedder: SentenceEmbedder()).sourceTimes(for: summary, segments: segments, languageCode: "de")
        #expect(times["Budget der Kampagne: 12.000 Euro"] == 10)
        #expect(times["Abstimmung mit der Agentur"] == 20)
        #expect(times["Welche Farbe hat das Logo?"] == nil)
    }

    @Test("Summaries saved before keywords existed still decode")
    func oldSummaryDecodes() throws {
        let json = """
        {"overview":"Alt","keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[],"topics":[],"source":"extractive","createdAt":0}
        """
        let summary = try JSONDecoder().decode(NoteSummary.self, from: Data(json.utf8))
        #expect(summary.overview == "Alt")
        #expect(summary.keywords.isEmpty)
        #expect(summary.sourceTimes.isEmpty)
    }
}

// MARK: - Chat

private struct MockAssistant: NoteAssistant {
    var answerText = "Das Budget beträgt 12.000 Euro [1]."
    var found = true

    func plan(question: String, history: [ChatTurn], now: Date) async throws -> AssistantPlan {
        AssistantPlan(searchQuery: question, relatedTerms: [], persons: [], timeframe: .none, wantsList: false)
    }

    func answer(question: String, sources: [AssistantSource], history: [ChatTurn], language: TranscriptionLanguage, now: Date) async throws -> AssistantAnswer {
        FoundationModelNoteAssistant.validated(answer: answerText, usedSources: [], answerFound: found, sourceCount: sources.count)
    }
}

@Suite("Chat with notes")
@MainActor
struct NoteChatTests {
    private func makeChat(available: Bool, assistant: MockAssistant = MockAssistant()) throws -> NoteChatModel {
        let store = try NoteStore(locations: try StorageLocations.temporary(), inMemory: true)
        let note = Note(title: "Marketing-Runde", isTitleUserDefined: true, kind: .recording, status: .ready, participants: ["Anna"])
        let segments = Fixture.segments(["Das Budget für die Kampagne liegt bei 12.000 Euro.", "Ben übernimmt die Agentur."])
        note.setTranscript(encoded: try Transcript.encode(segments), plainText: Transcript.plainText(of: segments), engine: .appleSpeech)
        try store.insert(note)
        let knowledge = KnowledgeIndexService(store: store, embedder: SentenceEmbedder(), persistence: nil)
        return NoteChatModel(
            knowledge: knowledge,
            settings: makeIsolatedSettings(),
            assistant: assistant,
            availability: { _ in available ? .available : .unavailable(reason: "Nicht verfügbar.") },
            now: { Fixture.now }
        )
    }

    @Test("An answer cites the passages it is based on")
    func answersWithSources() async throws {
        let chat = try makeChat(available: true)
        let message = await chat.respond(to: "Wie hoch ist das Budget?", history: [])
        #expect(message.text == "Das Budget beträgt 12.000 Euro [1].")
        #expect(message.sources.count == 1)
        #expect(message.sources.first?.noteTitle == "Marketing-Runde")
        #expect(message.sources.first?.excerpt.contains("12.000 Euro") == true)
    }

    @Test("Without Apple Intelligence the best passages are shown")
    func withoutModel() async throws {
        let chat = try makeChat(available: false)
        let message = await chat.respond(to: "Budget Kampagne", history: [])
        #expect(!message.sources.isEmpty)
        #expect(message.notice?.contains("Nicht verfügbar.") == true)
    }

    @Test("Filters without notes are reported")
    func emptyFilter() async throws {
        let chat = try makeChat(available: true)
        let message = await chat.respond(to: "Was war im Januar zum Budget?", history: [])
        #expect(message.text == "Für diese Filter gibt es keine Notizen.")
        #expect(message.filters.contains { $0.contains("Januar") })
    }

    @Test("An answer the sources do not support shows no sources")
    func notFound() async throws {
        let chat = try makeChat(available: true, assistant: MockAssistant(answerText: "Dazu steht nichts in deinen Notizen.", found: false))
        let message = await chat.respond(to: "Wie hoch ist das Budget?", history: [])
        #expect(message.sources.isEmpty)
        #expect(!message.notes.isEmpty)
    }
}
