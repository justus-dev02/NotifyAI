//
//  SummarizationTests.swift
//  NotifyAITests
//

import Foundation
@testable import NotifyAI
import NotifyAICore
import Testing

@Suite("Text chunking")
struct TextChunkerTests {
    @Test("Short text stays in one chunk")
    func shortText() async {
        let chunker = TextChunker(budget: 100)
        #expect(await chunker.chunks(of: "Ein kurzer Satz.") == ["Ein kurzer Satz."])
    }

    @Test("Long text is split at sentence boundaries within the budget")
    func splitsAtSentences() async {
        let sentences = (1...40).map { "Dies ist Satz Nummer \($0) mit etwas zusätzlichem Inhalt." }
        let text = sentences.joined(separator: " ")
        let chunker = TextChunker(budget: 60)
        let chunks = await chunker.chunks(of: text)

        #expect(chunks.count > 1)
        for chunk in chunks {
            #expect(await TextChunker.estimatedTokens(chunk) <= 60 + 2)
            #expect(chunk.hasSuffix("."))
        }
        // Nothing is lost or duplicated.
        #expect(chunks.joined(separator: " ") == text)
    }

    @Test("A sentence longer than the budget is split at word boundaries")
    func splitsLongSentence() async {
        let text = Array(repeating: "Wort", count: 300).joined(separator: " ")
        let chunks = await TextChunker(budget: 50).chunks(of: text)
        #expect(chunks.count > 1)
        #expect(chunks.joined(separator: " ") == text)
    }
}

@Suite("Extractive summary")
struct ExtractiveSummarizerTests {
    private let transcript = """
    Guten Morgen zusammen, heute geht es um den Relaunch der Website. \
    Wir haben beschlossen, den Launch auf den ersten Oktober zu legen. \
    Anna übernimmt die Abstimmung mit der Agentur bis Freitag. \
    Das Budget für die Kampagne ist noch unklar. \
    Die neue Startseite hat im Test deutlich besser abgeschnitten als die alte Startseite. \
    Mit dem Hosting gibt es kein Problem. \
    Wer kümmert sich um die Übersetzungen?
    """

    private func summarize(_ text: String) async throws -> NoteSummary {
        let request = SummaryRequest(text: text, language: .german, focus: .meeting, kind: .recording, markedPassages: [])
        return try await ExtractiveSummarizer().summarize(request) { _ in }
    }

    @Test("Decisions, tasks and open questions are recognised")
    func categories() async throws {
        let summary = try await summarize(transcript)
        #expect(summary.source == .extractive)
        #expect(summary.decisions.contains { $0.contains("beschlossen") })
        #expect(summary.actionItems.contains { $0.task.contains("Anna übernimmt") })
        #expect(summary.openQuestions.contains { $0.contains("unklar") })
        #expect(summary.openQuestions.contains { $0.hasSuffix("?") })
    }

    @Test("Negated cues are ignored")
    func negation() async throws {
        let summary = try await summarize(transcript)
        #expect(!summary.openQuestions.contains { $0.contains("kein Problem") })
    }

    @Test("Key points keep the original order")
    func order() async throws {
        let summary = try await summarize(transcript)
        let positions = summary.keyPoints.compactMap { transcript.range(of: $0)?.lowerBound }
        #expect(positions == positions.sorted())
    }

    @Test("Empty input throws")
    func emptyInput() async {
        await #expect(throws: SummarizationError.self) {
            try await summarize("  ")
        }
    }
}

@Suite("Summarizer selection")
struct SummarizationServiceTests {
    private let request = SummaryRequest(text: "Text", language: .german, focus: .general, kind: .document, markedPassages: [])

    @Test("The language model is used when available")
    func usesLanguageModel() async throws {
        let service = SummarizationService(
            languageModel: MockSummarizer(),
            fallback: MockSummarizer(result: NoteSummary(overview: "Fallback", source: .extractive)),
            availability: { _ in .available }
        )
        let summary = try await service.summarize(request) { _ in }
        #expect(summary.source == .appleIntelligence)
    }

    @Test("Unavailability falls back and explains why")
    func fallbackWhenUnavailable() async throws {
        let service = SummarizationService(
            languageModel: MockSummarizer(),
            fallback: MockSummarizer(result: NoteSummary(overview: "Fallback", source: .extractive)),
            availability: { _ in .unavailable(reason: "Nicht aktiviert.") }
        )
        let summary = try await service.summarize(request) { _ in }
        #expect(summary.source == .extractive)
        #expect(summary.fallbackReason == "Nicht aktiviert.")
    }

    @Test("A failing language model falls back instead of failing the note")
    func fallbackOnError() async throws {
        let service = SummarizationService(
            languageModel: MockSummarizer(error: TestError()),
            fallback: MockSummarizer(result: NoteSummary(overview: "Fallback", source: .extractive)),
            availability: { _ in .available }
        )
        let summary = try await service.summarize(request) { _ in }
        #expect(summary.source == .extractive)
        #expect(summary.fallbackReason != nil)
    }
}
