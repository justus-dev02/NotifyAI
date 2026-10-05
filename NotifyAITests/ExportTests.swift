//
//  ExportTests.swift
//  NotifyAITests
//

import Foundation
@testable import NotifyAI
import NotifyAICore
@testable import NotifyAIServices
import Testing

@Suite("Redaction")
struct RedactorTests {
    @Test("Personal data is replaced", arguments: [
        ("Schreib an max.mustermann@example.com.", "Schreib an [E-Mail]."),
        ("Ruf an unter +49 170 1234567 bitte", "Ruf an unter [Telefonnummer] bitte"),
        ("Festnetz 0711/1234567", "Festnetz [Telefonnummer]"),
        ("IBAN DE89 3704 0044 0532 0130 00 bitte", "IBAN [IBAN] bitte"),
        ("IBAN DE89370400440532013000", "IBAN [IBAN]"),
    ])
    func redacts(input: String, expected: String) {
        #expect(Redactor.redact(input) == expected)
    }

    @Test("Times, years and amounts stay untouched", arguments: [
        "Treffen um 14:30 Uhr",
        "Das war 2026",
        "Budget 1.500 Euro",
        "Version 18.6.2",
        "Kundennummer 4711",
    ])
    func keepsNumbers(input: String) {
        #expect(Redactor.redact(input) == input)
    }
}

@Suite("Markdown export")
struct MarkdownExporterTests {
    private var snapshot: MarkdownExporter.NoteSnapshot {
        MarkdownExporter.NoteSnapshot(
            title: "Sprint Review",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            duration: 125,
            participants: ["Anna", "Ben"],
            summary: NoteSummary(
                overview: "Das Team hat den Sprint abgeschlossen.",
                keyPoints: ["Alle Tickets erledigt"],
                decisions: ["Release am Montag"],
                actionItems: [ActionItem(task: "Release Notes schreiben", owner: "Anna", due: "Freitag")],
                source: .appleIntelligence
            ),
            markers: [Marker(time: 12)],
            segments: [TranscriptSegment(start: 10, end: 14, text: "Das ist wichtig, mail an ben@example.com")],
            bodyText: "Das ist wichtig, mail an ben@example.com"
        )
    }

    @Test("All sections are rendered")
    func sections() {
        let markdown = MarkdownExporter().markdown(for: snapshot)
        #expect(markdown.hasPrefix("# Sprint Review"))
        #expect(markdown.contains("## Überblick"))
        #expect(markdown.contains("- [ ] Release Notes schreiben (Anna, bis Freitag)"))
        #expect(markdown.contains("## Markierte Stellen"))
        #expect(markdown.contains("**00:12**"))
        #expect(markdown.contains("## Transkript"))
    }

    @Test("Redaction applies to the whole document")
    func redaction() {
        let options = MarkdownExporter.Options(includesTranscript: true, redactsPersonalData: true)
        let markdown = MarkdownExporter().markdown(for: snapshot, options: options)
        #expect(!markdown.contains("ben@example.com"))
        #expect(markdown.contains("[E-Mail]"))
    }

    @Test("The transcript can be left out")
    func withoutTranscript() {
        let options = MarkdownExporter.Options(includesTranscript: false)
        #expect(!MarkdownExporter().markdown(for: snapshot, options: options).contains("## Transkript"))
    }
}
