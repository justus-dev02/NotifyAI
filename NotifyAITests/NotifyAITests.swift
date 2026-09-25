//
//  NotifyAITests.swift
//  NotifyAITests
//
//  Created by Justus on 08.09.25.
//  Comprehensive Unit Test Suite for NotifyAI Intelligence & Domain Services.
//

import XCTest
@testable import NotifyAI

final class NotifyAITests: XCTestCase {
    var llmService: LLMService!
    var highlightService: HighlightService!
    var redactionService: RedactionService!
    var exportService: ExportService!

    override func setUp() {
        super.setUp()
        llmService = LLMService()
        highlightService = HighlightService(llm: llmService)
        redactionService = RedactionService()
        exportService = ExportService()
    }

    // MARK: - LLM & NLP Extraction Tests

    func testLLMSummaryExtraction() async {
        let sampleTranscript = """
        Guten Morgen zusammen. Wir haben heute beschlossen, den Kundenvertrag für die Horizon GmbH um ein weiteres Jahr zu verlängern.
        Max wird das finale Angebot bis Freitag an den Kunden schicken.
        Das Hauptrisiko ist die knappe Frist für das Security Audit.
        Anna übernimmt die Abstimmung mit dem Compliance Team.
        """

        let summary = await llmService.summarize(transcript: sampleTranscript)

        XCTAssertFalse(summary.highlights.isEmpty, "Highlights should be extracted")
        XCTAssertFalse(summary.decisions.isEmpty, "Decisions should be identified")
        XCTAssertFalse(summary.actionItems.isEmpty, "Action items should be identified")
        XCTAssertFalse(summary.risks.isEmpty, "Risks should be identified")

        // Verify NER Owner Assignment
        let hasMaxOrAnna = summary.actionItems.contains { item in
            item.owner == "Max" || item.owner == "Anna"
        }
        XCTAssertTrue(hasMaxOrAnna, "Action items should assign real person names from transcript via NER")
    }

    // MARK: - Highlight & Role Summary Tests

    func testRoleSummaryGeneration() async throws {
        let transcript = "Der Kunde möchte das Enterprise Paket kaufen. Unser Sprint Ziel für Entwickler ist das API Refactoring."
        let segments = [
            TranscriptSegment(start: 0, end: 10, speakerId: "Sprecher 1", text: "Der Kunde möchte das Enterprise Paket kaufen."),
            TranscriptSegment(start: 11, end: 20, speakerId: "Sprecher 2", text: "Unser Sprint Ziel für Entwickler ist das API Refactoring.")
        ]

        let salesSummary = try await highlightService.roleSummary(role: "Sales", transcript: transcript, segments: segments)
        XCTAssertTrue(salesSummary.markdown.contains("Sales"), "Sales role summary should include Sales header")
    }

    func testMindmapGeneration() async throws {
        let transcript = "Thema Strategie: Wir planen eine Expansion in die Schweiz. Thema Produkt: Ein neues Dashboard wird entwickelt."

        let mindmap = try await highlightService.makeMindmap(transcript: transcript)
        XCTAssertFalse(mindmap.root.isEmpty, "Mindmap root should not be empty")
        XCTAssertFalse(mindmap.children.isEmpty, "Mindmap should have thematic branches")
    }

    // MARK: - Redaction & PII Tests

    func testPIIRedaction() {
        let sensitiveText = "Kontaktieren Sie max.mustermann@example.com oder rufen Sie unter +49 170 1234567 an."
        let redacted = redactionService.redactPII(sensitiveText)

        XCTAssertFalse(redacted.contains("max.mustermann@example.com"), "Email should be redacted")
        XCTAssertTrue(redacted.contains("[E-Mail]") || redacted.contains("[REDACTED]"), "Placeholder should be present")
    }

    // MARK: - Export Service Tests

    func testMermaidCodeGeneration() {
        let mindmap = Mindmap(
            root: "Projektstart",
            children: [
                MindmapNode(label: "Budget", children: [MindmapNode(label: "50k", children: nil)]),
                MindmapNode(label: "Team", children: nil)
            ]
        )

        let code = exportService.generateMermaidCode(from: mindmap)
        XCTAssertTrue(code.hasPrefix("mindmap"), "Mermaid output must start with mindmap keyword")
        XCTAssertTrue(code.contains("Projektstart"), "Mermaid output must contain root title")
        XCTAssertTrue(code.contains("Budget"), "Mermaid output must contain child node")
    }

    // MARK: - Model Codable Persistence Tests

    func testNoteCodableSerialization() throws {
        var note = Note(title: "Codable Test Note")
        note.location = "Berlin"
        note.duration = 120
        note.summary = Summary(
            highlights: ["Wichtiger Meilenstein erreicht"],
            decisions: ["Go-Live am Freitag"],
            actionItems: [ActionItem(owner: "Justus", task: "Release vorbereiten", status: .open)],
            risks: ["Serverauslastung"],
            markdown: "### Test Markdown"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(note)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Note.self, from: data)

        XCTAssertEqual(decoded.title, "Codable Test Note")
        XCTAssertEqual(decoded.location, "Berlin")
        XCTAssertEqual(decoded.summary?.highlights.count, 1)
        XCTAssertEqual(decoded.summary?.actionItems.first?.owner, "Justus")
    }
}
