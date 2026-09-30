//
//  SpeechChunkerTests.swift
//  NotifyAITests
//

@testable import NotifyAI
import NotifyAICore
import Testing

@Suite("Whisper chunking")
struct SpeechChunkerTests {
    private func run(_ samples: [Float]) -> [AudioChunk] {
        var chunker = SpeechChunker()
        var output: [AudioChunk] = []
        for chunk in Signal.chunks(of: samples) {
            output += chunker.append(chunk)
        }
        if let tail = chunker.flush() {
            output.append(tail)
        }
        return output
    }

    @Test("Audio is cut at a pause once the minimum length is reached")
    func cutsAtPause() {
        let speech = Signal.voice(seconds: 8, frequency: 140, overtoneDecay: 0.7)
        let samples = speech + Signal.silence(seconds: 1) + speech
        let chunks = run(samples)

        #expect(chunks.count == 2)
        // The cut lies inside the pause (between 8 s and 9 s).
        let cut = chunks[1].startTime
        #expect(cut > 8 && cut < 9)
    }

    @Test("Chunks are contiguous: no audio is lost between them")
    func contiguous() {
        let speech = Signal.voice(seconds: 7, frequency: 140, overtoneDecay: 0.7)
        let samples = speech + Signal.silence(seconds: 0.8) + speech + Signal.silence(seconds: 0.8) + speech
        let chunks = run(samples)

        #expect(chunks.first?.startFrame == 0)
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            #expect(previous.endFrame == next.startFrame)
        }
        #expect(chunks.map(\.samples.count).reduce(0, +) == samples.count)
    }

    @Test("Continuous speech is cut at the maximum length")
    func maximumLength() {
        let samples = Signal.voice(seconds: 40, frequency: 140, overtoneDecay: 0.7)
        let chunks = run(samples)
        #expect(chunks.count >= 2)
        #expect(chunks.allSatisfy { $0.duration <= SpeechChunker.Configuration().maximumChunkDuration + 0.01 })
    }

    @Test("Silent audio is dropped")
    func dropsSilence() {
        let chunks = run(Signal.silence(seconds: 30))
        #expect(chunks.isEmpty)
    }

    @Test("Quiet speech in background noise is never dropped")
    func keepsQuietSpeechInNoise() {
        let noise = Signal.noise(seconds: 30, amplitude: 0.02)
        let speech = Signal.voice(seconds: 30, frequency: 180, overtoneDecay: 0.6, amplitude: 0.03)
        let mixed = zip(noise, speech).map(+)
        let chunks = run(mixed)
        #expect(chunks.map(\.samples.count).reduce(0, +) == mixed.count)
    }
}
