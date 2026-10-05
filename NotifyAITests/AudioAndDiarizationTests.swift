//
//  AudioAndDiarizationTests.swift
//  NotifyAITests
//

import AVFoundation
@testable import NotifyAI
import NotifyAICore
@testable import NotifyAIPersistence
@testable import NotifyAIServices
import Testing

@Suite("Recording file format")
struct RecordingFileTests {
    @Test("AAC in CAF is written and read back with the right length")
    func writeAndRead() throws {
        let locations = try StorageLocations.temporary()
        let url = locations.audioURL(fileName: "test.\(AudioFormat.recordingFileExtension)")
        let samples = Signal.voice(seconds: 3, frequency: 150, overtoneDecay: 0.7)

        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: AudioFormat.recordingFileSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            for chunk in Signal.chunks(of: samples, size: 4_096) {
                let buffer = try #require(AVAudioPCMBuffer.mono(chunk.samples))
                try file.write(from: buffer)
            }
        }

        let decoded = try SpeakerDiarizer.readMonoSamples(from: url)
        // AAC adds encoder priming and padding of a few thousand samples at most.
        #expect(abs(decoded.count - samples.count) < 4_096)
        #expect(decoded.contains { abs($0) > 0.05 })
    }
}

@Suite("Clustering")
struct ClusteringTests {
    @Test("Clearly separated groups form separate clusters")
    func separatesGroups() {
        var generator = SeededGenerator(seed: 7)
        func jitter() -> Float { Float.random(in: -0.05...0.05, using: &generator) }
        let groupA = (0..<10).map { _ in [1 + jitter(), jitter(), jitter()] }
        let groupB = (0..<10).map { _ in [jitter(), 1 + jitter(), jitter()] }

        let labels = AgglomerativeClustering.cluster(groupA + groupB, threshold: 0.5, maximumClusters: 6)
        #expect(Set(labels.prefix(10)).count == 1)
        #expect(Set(labels.suffix(10)).count == 1)
        #expect(labels.first != labels.last)
    }

    @Test("The maximum number of clusters is respected")
    func maximumClusters() {
        let vectors: [[Float]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1], [1, 1, 0]]
        let labels = AgglomerativeClustering.cluster(vectors, threshold: 0.01, maximumClusters: 2)
        #expect(Set(labels).count == 2)
    }
}

@Suite("Speaker detection")
struct SpeakerDiarizerTests {
    private let voiceA = Signal.voice(seconds: 4, frequency: 110, overtoneDecay: 0.85)
    private let voiceB = Signal.voice(seconds: 4, frequency: 240, overtoneDecay: 0.45)
    private let pause = Signal.silence(seconds: 0.5)

    /// Adds low background noise so that windows of the same voice are not identical.
    private func withNoise(_ samples: [Float]) -> [Float] {
        zip(samples, Signal.noise(seconds: Double(samples.count) / Signal.sampleRate + 1, amplitude: 0.003)).map(+)
    }

    @Test("Two clearly different voices are told apart")
    func twoSpeakers() {
        var samples: [Float] = []
        for _ in 0..<3 {
            samples += voiceA + pause + voiceB + pause
        }
        let turns = SpeakerDiarizer().turns(for: withNoise(samples))

        #expect(Set(turns.map(\.speaker)) == [0, 1])
        // Speakers alternate like the input.
        let order = turns.map(\.speaker).reduce(into: [Int]()) { result, speaker in
            if result.last != speaker { result.append(speaker) }
        }
        #expect(order == [0, 1, 0, 1, 0, 1])
    }

    @Test("A single voice yields no speaker labels")
    func singleSpeaker() {
        let samples = voiceA + pause + voiceA + pause + voiceA
        #expect(SpeakerDiarizer().turns(for: withNoise(samples)).isEmpty)
    }

    @Test("The same voice at a different loudness stays one speaker")
    func loudnessInvariance() {
        let quiet = voiceA.map { $0 * 0.25 }
        let samples = voiceA + pause + quiet + pause + voiceA + pause + quiet
        #expect(SpeakerDiarizer().turns(for: withNoise(samples)).isEmpty)
    }

    @Test("Segments get the speaker with the largest overlap")
    func assignment() {
        let turns = [SpeakerTurn(start: 0, end: 4, speaker: 0), SpeakerTurn(start: 4, end: 8, speaker: 1)]
        let segments = [
            TranscriptSegment(start: 0.5, end: 3, text: "A"),
            TranscriptSegment(start: 3.5, end: 7.5, text: "B"),
        ]
        let result = SpeakerDiarizer.assignSpeakers(turns, to: segments)
        #expect(result.map(\.speaker) == ["Sprecher 1", "Sprecher 2"])
    }
}
