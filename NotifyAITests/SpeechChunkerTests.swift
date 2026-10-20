//
//  SpeechChunkerTests.swift
//  NotifyAITests
//

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

    @Test("A single click does not let silence through")
    func dropsSilenceWithClick() {
        var samples = Signal.silence(seconds: 10)
        // 20 ms, one analysis frame.
        for index in 80_000..<80_320 {
            samples[index] = index.isMultiple(of: 2) ? 0.3 : -0.3
        }
        #expect(run(samples).isEmpty)
    }

    @Test("Short noises below the minimum audible duration are dropped")
    func dropsShortNoises() {
        var samples = Signal.silence(seconds: 20)
        // Five clicks of 40 ms: 0.2 s in total.
        for second in stride(from: 2, to: 20, by: 4) {
            let start = second * Int(Signal.sampleRate)
            for index in start..<(start + 640) {
                samples[index] = index.isMultiple(of: 2) ? 0.2 : -0.2
            }
        }
        #expect(run(samples).isEmpty)
    }

    @Test("A short word in silence is kept")
    func keepsShortWord() {
        let samples = Signal.silence(seconds: 5) + Signal.voice(seconds: 0.4, frequency: 140, overtoneDecay: 0.7) + Signal.silence(seconds: 5)
        let chunks = run(samples)
        #expect(chunks.count == 1)
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
