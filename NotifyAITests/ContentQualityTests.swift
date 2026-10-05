//
//  ContentQualityTests.swift
//  NotifyAITests
//
//  What keeps made-up content out of notes: transcript text without speech in the audio,
//  summaries of nearly empty transcripts, tasks and decisions the text does not support and
//  placeholder owners.
//

import Foundation
import NotifyAICore
@testable import NotifyAIServices
import Synchronization
import Testing

// MARK: - Transcript against audio

@Suite("Transcript verification against the audio")
struct TranscriptVerificationTests {
    /// 30 s: background noise, a voice from 10 to 14 s, noise again.
    private func evidence() -> SpeechEvidence {
        let samples = Signal.noise(seconds: 10, amplitude: 0.003)
            + Signal.voice(seconds: 4, frequency: 150, overtoneDecay: 0.7)
            + Signal.noise(seconds: 16, amplitude: 0.003)
        return SpeechEvidence(levels: SpeechEvidence.levels(of: samples))
    }

    @Test("Text over background noise is removed, text over speech is kept")
    func silenceHallucinations() {
        let segments = [
            TranscriptSegment(start: 0, end: 9, text: "Vielen Dank."),
            TranscriptSegment(start: 10, end: 14, text: "Wir starten das Budget im Oktober."),
            TranscriptSegment(start: 15, end: 22, text: "Vielen Dank."),
            TranscriptSegment(start: 22, end: 29, text: "Untertitel im Auftrag des ZDF"),
        ]
        let verified = TranscriptVerifier().verify(segments, against: evidence())
        #expect(verified.map(\.text) == ["Wir starten das Budget im Oktober."])
    }

    @Test("A typical phrase that was really said is kept")
    func realThanks() {
        let segments = [TranscriptSegment(start: 10.5, end: 13.5, text: "Vielen Dank.")]
        #expect(TranscriptVerifier().verify(segments, against: evidence()).count == 1)
    }

    @Test("A recording of silence keeps no text at all")
    func onlySilence() {
        let silence = SpeechEvidence(levels: SpeechEvidence.levels(of: Signal.noise(seconds: 60, amplitude: 0.003)))
        let segments = stride(from: 0.0, to: 60, by: 22.5).map {
            TranscriptSegment(start: $0, end: min(60, $0 + 20), text: "Vielen Dank.")
        }
        #expect(TranscriptVerifier().verify(segments, against: silence).isEmpty)
    }

    @Test("Phrases are compared without case, punctuation and spacing")
    func normalization() {
        #expect(TranscriptVerifier.normalized("  Vielen   Dank! ") == "vielen dank")
        #expect(TranscriptVerifier.typicalHallucinations.contains(TranscriptVerifier.normalized("Untertitel der Amara.org-Community")))
    }
}

// MARK: - Summaries

@Suite("Summary grounding")
struct SummaryGroundingTests {
    private let transcript = "Anna schickt die Folien bis Freitag an Ben. Wir haben das Budget für die Kampagne auf 12.000 Euro festgelegt."

    @Test("Tasks, decisions and questions the text does not support are removed")
    func inventedItems() {
        let summary = NoteSummary(
            overview: "Planung",
            decisions: ["Budget der Kampagne auf 12.000 Euro festgelegt", "Zustimmung zu den neuen Zeitplänen"],
            actionItems: [
                ActionItem(task: "Folien an Ben schicken", owner: "Anna", due: "Freitag"),
                ActionItem(task: "Umsetzung der nächsten Schritte"),
            ],
            openQuestions: ["Unklarheiten bei der Ressourcenplanung"],
            source: .appleIntelligence
        )
        let grounded = SummaryGrounding(text: transcript, languageCode: "de").apply(to: summary)
        #expect(grounded.actionItems.map(\.task) == ["Folien an Ben schicken"])
        #expect(grounded.decisions == ["Budget der Kampagne auf 12.000 Euro festgelegt"])
        #expect(grounded.openQuestions.isEmpty)
    }

    @Test("Placeholders written instead of an owner or deadline are removed", arguments: [
        "nicht angegeben", "keine", "Keine Angabe", "n/a", "unknown", "–", " ",
    ])
    func placeholders(value: String) {
        #expect(SummaryGrounding.cleaned(value) == nil)
    }

    @Test("Real owners and deadlines are kept")
    func realFields() {
        #expect(SummaryGrounding.cleaned("Anna") == "Anna")
        #expect(SummaryGrounding.cleaned("bis Freitag") == "bis Freitag")
    }

    @Test("A nearly empty transcript is not handed to the language model")
    func thinContent() async throws {
        let counting = CountingSummarizer()
        let service = SummarizationService(languageModel: counting, fallback: ExtractiveSummarizer(), availability: { _ in .available })
        let request = SummaryRequest(text: "Vielen Dank. Vielen Dank.", language: .german, focus: .meeting, kind: .recording, markedPassages: [])
        #expect(SummarizationService.isTooThin(request))

        let summary = try await service.summarize(request) { _ in }
        #expect(counting.calls == 0)
        #expect(summary.actionItems.isEmpty)
        #expect(summary.decisions.isEmpty)
        #expect(summary.processingNotes.contains { $0.contains("zu wenig Inhalt") })
    }

    @Test("The simple summary takes only commitments and assigned obligations as tasks")
    func extractiveTasks() async throws {
        let text = """
        Das muss man ehrlich sagen, die Präsentation war sehr gelungen. \
        Ich kümmere mich um die Einladung zur nächsten Sitzung. \
        Wir müssen das Angebot bis Freitag an den Kunden schicken. \
        Die Zahlen sollen im Bericht vollständig erscheinen.
        """
        let request = SummaryRequest(text: text, language: .german, focus: .meeting, kind: .document, markedPassages: [])
        let summary = try await ExtractiveSummarizer().summarize(request) { _ in }
        #expect(summary.actionItems.map(\.task) == [
            "Ich kümmere mich um die Einladung zur nächsten Sitzung.",
            "Wir müssen das Angebot bis Freitag an den Kunden schicken.",
        ])
    }
}

/// Counts calls; never expected to be asked for a thin transcript.
private final class CountingSummarizer: Summarizer {
    private let count = Mutex(0)

    var calls: Int { count.withLock { $0 } }

    func summarize(_ request: SummaryRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> NoteSummary {
        count.withLock { $0 += 1 }
        return NoteSummary(overview: "Erfunden", actionItems: [ActionItem(task: "Erfunden")], source: .appleIntelligence)
    }
}
