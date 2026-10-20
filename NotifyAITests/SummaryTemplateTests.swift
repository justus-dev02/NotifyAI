//
//  SummaryTemplateTests.swift
//  NotifyAITests
//
//  Templates of the user's own: their instructions reach the model, left-out sections stay
//  empty with every summarizer, and their headings are filled from the text.
//

import Foundation
import FoundationModels
@testable import NotifyAI
import NotifyAICore
@testable import NotifyAIPersistence
@testable import NotifyAIServices
import Synchronization
import Testing

/// Answers like a model that fills every list, and records the instructions it received.
final class TemplateResponder: LanguageModelResponder {
    private let calls = Mutex<[(instructions: String, prompt: String)]>([])
    let sections: [[String]]?

    init(sections: [[String]]? = nil) {
        self.sections = sections
    }

    var instructions: [String] { calls.withLock { $0.map(\.instructions) } }

    func respond<Content: Generable>(generating type: Content.Type, instructions: String, prompt: String) async throws -> Content {
        calls.withLock { $0.append((instructions, prompt)) }
        let summary = GeneratedSummary(
            title: "Kundentermin",
            overview: "Der Kunde wünscht einen Relaunch der Website.",
            keyPoints: ["Der Kunde wünscht einen Relaunch."],
            decisions: ["Das Budget liegt bei 18.000 Euro."],
            actionItems: [GeneratedActionItem(quote: "", task: "Angebot an den Kunden schicken", owner: "Anna", due: "")],
            openQuestions: ["Wer pflegt die Website?"],
            topics: [GeneratedTopic(title: "Website", points: ["Relaunch"])],
            keywords: ["Relaunch"]
        )
        guard let content = summary as? Content else { throw TestError() }
        return content
    }

    func respondSections(headings: [String], instructions: String, prompt: String) async throws -> [[String]] {
        calls.withLock { $0.append((instructions, prompt)) }
        guard let sections else { throw TestError() }
        return sections
    }
}

@Suite("Summary templates")
struct SummaryTemplateTests {
    let text = "Der Kunde wünscht einen Relaunch der Website. Das Budget liegt bei 18.000 Euro. Anna schickt das Angebot an den Kunden. Wer die Website später pflegt, ist offen. Der Kunde hat Bedenken wegen des Zeitplans."

    private func request(_ template: TemplateGuidance?) -> SummaryRequest {
        SummaryRequest(text: text, language: .german, focus: .sales, kind: .recording, markedPassages: [], template: template)
    }

    private func service(_ responder: TemplateResponder) -> SummarizationService {
        SummarizationService(
            languageModel: FoundationModelSummarizer(responder: responder, measure: TextChunker.estimatedTokens),
            fallback: ExtractiveSummarizer(),
            availability: { _ in .available }
        )
    }

    @Test("The template's instructions replace the kind of conversation; left-out sections stay empty")
    func instructionsAndSections() async throws {
        let responder = TemplateResponder()
        let template = TemplateGuidance(name: "Vertrieb", instructions: "Achte auf Einwände des Kunden.", sections: [.keyPoints, .actionItems], headings: [])
        let summary = try await service(responder).summarize(request(template)) { _ in }

        let instructions = try #require(responder.instructions.first)
        #expect(instructions.contains("Achte auf Einwände des Kunden."))
        #expect(!instructions.contains(RecordingFocus.sales.modelGuidance))
        #expect(instructions.contains("decisions, openQuestions, topics"))
        // The model filled every list; the summary keeps only the chosen ones.
        #expect(summary.keyPoints == ["Der Kunde wünscht einen Relaunch."])
        #expect(summary.actionItems.count == 1)
        #expect(summary.decisions.isEmpty)
        #expect(summary.openQuestions.isEmpty)
        #expect(summary.topics.isEmpty)
    }

    @Test("Without a template, the kind of conversation guides the summary as before")
    func withoutTemplate() async throws {
        let responder = TemplateResponder()
        let summary = try await service(responder).summarize(request(nil)) { _ in }
        #expect(responder.instructions.first?.contains(RecordingFocus.sales.modelGuidance) == true)
        #expect(!summary.decisions.isEmpty)
    }

    @Test("The template's own headings are filled in their order")
    func headings() async throws {
        let responder = TemplateResponder(sections: [["Bedenken wegen des Zeitplans."], []])
        let template = TemplateGuidance(name: "Vertrieb", instructions: "", sections: [.keyPoints], headings: ["Einwände", "Wettbewerb"])
        let summary = try await service(responder).summarize(request(template)) { _ in }
        #expect(summary.templateSections.map(\.title) == ["Einwände", "Wettbewerb"])
        #expect(summary.templateSections[0].points == ["Bedenken wegen des Zeitplans."])
        #expect(summary.templateSections[1].points.isEmpty)
        #expect(summary.processingNotes.isEmpty)
    }

    @Test("When the headings fail, the summary stays and says so")
    func headingsFail() async throws {
        let responder = TemplateResponder(sections: nil)
        let template = TemplateGuidance(name: "Vertrieb", instructions: "", sections: [.keyPoints], headings: ["Einwände"])
        let summary = try await service(responder).summarize(request(template)) { _ in }
        #expect(summary.source == .appleIntelligence)
        #expect(summary.templateSections.isEmpty)
        #expect(summary.processingNotes.contains { $0.contains("Vertrieb") })
    }

    @Test("Without Apple Intelligence the sections are respected and missing headings noted")
    func fallback() async throws {
        let service = SummarizationService(
            languageModel: FoundationModelSummarizer(responder: TemplateResponder(), measure: TextChunker.estimatedTokens),
            fallback: ExtractiveSummarizer(),
            availability: { _ in .unavailable(reason: "Nicht verfügbar") }
        )
        let template = TemplateGuidance(name: "Vertrieb", instructions: "", sections: [.keyPoints], headings: ["Einwände"])
        let summary = try await service.summarize(request(template)) { _ in }
        #expect(summary.source == .extractive)
        #expect(summary.actionItems.isEmpty && summary.decisions.isEmpty && summary.openQuestions.isEmpty)
        #expect(summary.processingNotes.contains { $0.contains("„Vertrieb“") })
    }

    @Test("Points under a heading that the text does not support are dropped")
    func grounding() {
        let summary = NoteSummary(
            overview: "",
            source: .appleIntelligence,
            templateSections: [SummaryTopic(title: "Einwände", points: ["Bedenken wegen des Zeitplans.", "Quantencomputer explodieren."])]
        )
        let grounded = SummaryGrounding(text: text, languageCode: "de").apply(to: summary)
        #expect(grounded.templateSections.first?.points == ["Bedenken wegen des Zeitplans."])
    }
}

@Suite("Managing templates")
@MainActor
struct TemplateLibraryTests {
    let store: NoteStore
    let templates: SummaryTemplates

    init() throws {
        store = try NoteStore(locations: try StorageLocations.temporary(), inMemory: true)
        let settings = makeIsolatedSettings()
        let engine = MockTranscriptionEngine(kind: .appleSpeech)
        let processing = ProcessingCoordinator(
            store: store,
            settings: settings,
            transcription: TranscriptionService(appleSpeech: engine, whisper: engine, parakeet: engine),
            summarization: SummarizationService(languageModel: MockSummarizer(), fallback: MockSummarizer(), availability: { _ in .available }),
            diarizer: SpeakerDiarizer()
        )
        templates = SummaryTemplates(store: store, processing: processing, settings: settings.analysis)
    }

    @Test("A template needs a name and something to summarize")
    func validation() {
        var draft = SummaryTemplates.Draft()
        #expect(throws: SummaryTemplateError.self) { try templates.create(draft) }
        draft.name = "Vertrieb"
        draft.sections = []
        #expect(throws: SummaryTemplateError.self) { try templates.create(draft) }
        draft.headings = ["  ", "Einwände"]
        #expect(throws: Never.self) { try templates.create(draft) }
    }

    @Test("Notes use their template until it is deleted, then their kind of conversation")
    func choiceAndDeletion() async throws {
        var draft = SummaryTemplates.Draft()
        draft.name = " Vertrieb "
        draft.headings = ["Einwände", ""]
        let template = try templates.create(draft)
        #expect(template.name == "Vertrieb")
        #expect(template.customHeadings == ["Einwände"])

        let note = Note(title: "Termin", isTitleUserDefined: true, kind: .document, status: .ready, bodyText: "Text")
        try store.insert(note)
        templates.summarize(note, with: .custom(template.id))
        #expect(note.summaryTemplateID == template.id)
        #expect(templates.choice(for: note) == .custom(template.id))
        #expect(TemplateLookup(store: store).guidance(for: note)?.headings == ["Einwände"])

        try templates.delete(template)
        #expect(templates.choice(for: note) == .focus(.general))
        #expect(TemplateLookup(store: store).guidance(for: note) == nil)
    }

    @Test("The template's headings are part of the export")
    func export() {
        let summary = NoteSummary(
            overview: "Überblick",
            keyPoints: ["Punkt"],
            source: .appleIntelligence,
            templateSections: [SummaryTopic(title: "Einwände", points: ["Zeitplan"]), SummaryTopic(title: "Leer", points: [])]
        )
        let snapshot = MarkdownExporter.NoteSnapshot(
            title: "Termin", createdAt: .now, duration: 0, participants: [], summary: summary,
            markers: [], segments: [], bodyText: "", audioSource: nil
        )
        let markdown = MarkdownExporter().markdown(for: snapshot)
        #expect(markdown.contains("## Einwände\n\n- Zeitplan"))
        #expect(!markdown.contains("## Leer"))
    }
}
