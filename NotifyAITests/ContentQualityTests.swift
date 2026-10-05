//
//  ContentQualityTests.swift
//  NotifyAITests
//
//  What keeps made-up content out of notes: transcript text without speech in the audio.
//

import Foundation
import NotifyAICore
@testable import NotifyAIServices
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
