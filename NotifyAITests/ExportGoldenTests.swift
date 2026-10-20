//
//  ExportGoldenTests.swift
//  NotifyAITests
//
//  One rich note in every export format: the content is complete and identical across
//  formats, and the Markdown stays exactly as it was.
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
@testable import NotifyAIProcessing
@testable import NotifyAIRecording
@testable import NotifyAIServices
@testable import NotifyAISettings
@testable import NotifyAISpeakers
@testable import NotifyAISummarization
@testable import NotifyAISupport
@testable import NotifyAITranscription
import Testing

enum ExportFixture {
    static let createdAt = Date(timeIntervalSince1970: 1_790_000_000)

    static var snapshot: MarkdownExporter.NoteSnapshot {
        let summary = NoteSummary(
            overview: "Das Team plant den Relaunch der Website.",
            keyPoints: ["Budget 18.000 Euro", "Start im November"],
            decisions: ["Agentur B wird beauftragt"],
            actionItems: [
                ActionItem(task: "Zusage schicken", owner: "Eddy", due: "Freitag"),
                ActionItem(task: "Texte schreiben", owner: "Anna", isDone: true),
                ActionItem(task: "Hosting klären"),
            ],
            openQuestions: ["Wer pflegt die Seite?"],
            topics: [SummaryTopic(title: "Budget", points: ["Angebote verglichen"])],
            source: .appleIntelligence,
            chapters: [
                SummaryChapter(start: 0, end: 600, title: "Budget", overview: "Angebote"),
                SummaryChapter(start: 600, end: 1_200, title: "Zeitplan", overview: ""),
            ],
            templateSections: [SummaryTopic(title: "Risiken", points: ["Termin ist knapp"])]
        )
        let segments = [
            TranscriptSegment(start: 1, end: 4, text: "Guten Morgen zusammen.", speaker: "Anna"),
            TranscriptSegment(start: 4, end: 9, text: "Ich habe die Angebote verglichen, schreib an max@example.com.", speaker: "Eddy"),
            TranscriptSegment(start: 65, end: 70, text: "Dann machen wir das so."),
        ]
        return MarkdownExporter.NoteSnapshot(
            title: "Weekly: Relaunch",
            createdAt: createdAt,
            duration: 1_250,
            participants: ["Anna", "Eddy"],
            summary: summary,
            markers: [Marker(time: 5), Marker(time: 300)],
            segments: segments,
            bodyText: "",
            audioSource: "Mikrofon + Zoom"
        )
    }
}

@Suite("Export: golden note")
struct ExportGoldenTests {
    @Test("Markdown is exactly as before the shared document")
    func markdown() {
        let markdown = MarkdownExporter().markdown(for: ExportFixture.snapshot)
        #expect(markdown == Self.expectedMarkdown)
    }

    /// The Markdown of the golden note, as the exporter wrote it before the shared document.
    static var expectedMarkdown: String {
        let metadata = [
            ExportFixture.createdAt.formatted(date: .long, time: .shortened),
            TimeFormatting.duration(1_250),
            "Mikrofon + Zoom",
            "Teilnehmende: Anna, Eddy",
        ].joined(separator: " · ")
        return """
        # Weekly: Relaunch

        _\(metadata)_

        ## Überblick

        Das Team plant den Relaunch der Website.

        ## Kapitel

        1. **Budget** (00:00–10:00): Angebote
        2. **Zeitplan** (10:00–20:00)

        ## Kernpunkte

        - Budget 18.000 Euro
        - Start im November

        ## Risiken

        - Termin ist knapp

        ## Entscheidungen

        - Agentur B wird beauftragt

        ## Aufgaben

        - [ ] Zusage schicken (Eddy, bis Freitag)
        - [x] Texte schreiben (Anna)
        - [ ] Hosting klären

        ## Offene Fragen

        - Wer pflegt die Seite?

        ## Themen

        ### Budget

        - Angebote verglichen

        ## Markierte Stellen

        - **00:05** Guten Morgen zusammen. Ich habe die Angebote verglichen, schreib an max@example.com.
        - **05:00** _Keine Sprache an dieser Stelle_

        ## Transkript

        [00:01] **Anna:** Guten Morgen zusammen.

        [00:04] **Eddy:** Ich habe die Angebote verglichen, schreib an max@example.com.

        [01:05] Dann machen wir das so.


        """
    }

    @Test("Redaction reaches every block, the structure stays")
    func redaction() {
        let document = ExportDocument(note: ExportFixture.snapshot, options: .init(redactsPersonalData: true))
        let markdown = MarkdownExporter().render(document)
        #expect(!markdown.contains("max@example.com"))
        #expect(markdown.contains("[E-Mail]"))
        #expect(document.blocks.count == ExportDocument(note: ExportFixture.snapshot).blocks.count)
    }
}
