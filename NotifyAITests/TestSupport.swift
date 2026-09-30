//
//  TestSupport.swift
//  NotifyAITests
//

import AudioCapture
import Foundation
@testable import NotifyAI
import NotifyAICore
import Synchronization

/// Synthetic audio signals at the app's sample rate.
enum Signal {
    static let sampleRate = AudioFormat.sampleRate

    static func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * sampleRate))
    }

    /// A harmonic tone: fundamental `frequency` with overtones whose strength follows
    /// `overtoneDecay`. Different values give clearly different spectral envelopes.
    static func voice(seconds: Double, frequency: Double, overtoneDecay: Double, amplitude: Float = 0.2) -> [Float] {
        let count = Int(seconds * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        let harmonics = Int(7_000 / frequency)
        for index in 0..<count {
            let time = Double(index) / sampleRate
            var value = 0.0
            for harmonic in 1...harmonics {
                value += pow(overtoneDecay, Double(harmonic - 1)) * sin(2 * .pi * frequency * Double(harmonic) * time)
            }
            // Slow amplitude modulation, roughly like syllables.
            let envelope = 0.6 + 0.4 * sin(2 * .pi * 4 * time)
            samples[index] = amplitude * Float(value * envelope / Double(harmonics).squareRoot())
        }
        return samples
    }

    /// Low-level deterministic noise.
    static func noise(seconds: Double, amplitude: Float) -> [Float] {
        var generator = SeededGenerator(seed: 42)
        return (0..<Int(seconds * sampleRate)).map { _ in Float.random(in: -amplitude...amplitude, using: &generator) }
    }

    /// Splits samples into chunks the size of typical recorder buffers.
    static func chunks(of samples: [Float], size: Int = 1_365, startingAt startFrame: Int64 = 0) -> [AudioChunk] {
        stride(from: 0, to: samples.count, by: size).map { offset in
            AudioChunk(samples: Array(samples[offset..<min(offset + size, samples.count)]), startFrame: startFrame + Int64(offset))
        }
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

// MARK: - Mocks

struct MockTranscriptionEngine: TranscriptionEngine {
    let kind: TranscriptionEngineKind
    var segments: [TranscriptSegment] = [TranscriptSegment(start: 0, end: 2, text: "Hallo zusammen.")]
    var error: (any Error)?

    func startLiveSession(options: TranscriptionOptions) async throws -> any LiveTranscriptionSession {
        throw TranscriptionError.speechAssetsUnavailable
    }

    func transcribeFile(
        at url: URL,
        options: TranscriptionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        if let error { throw error }
        progress(1)
        return segments
    }
}

struct MockSummarizer: Summarizer {
    var result: NoteSummary = NoteSummary(suggestedTitle: "Projekt-Update", overview: "Überblick", source: .appleIntelligence, keywords: ["Projekt-Update"])
    var error: (any Error)?

    func summarize(_ request: SummaryRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> NoteSummary {
        if let error { throw error }
        return result
    }
}

struct TestError: LocalizedError {
    var errorDescription: String? { "Testfehler" }
}

@MainActor
func makeIsolatedSettings() -> AppSettings {
    let suiteName = "NotifyAITests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return AppSettings(defaults: defaults)
}

extension AudioCaptureContext {
    /// `finish()` for synchronous test code such as `XCTestCase.measure`. Waits on the
    /// calling thread; the capture finishes on its own queue, so this cannot deadlock.
    func finishBlocking() -> RecordingResult {
        let semaphore = DispatchSemaphore(value: 0)
        let result = Mutex<RecordingResult?>(nil)
        Task.detached {
            let finished = await self.finish()
            result.withLock { $0 = finished }
            semaphore.signal()
        }
        semaphore.wait()
        return result.withLock { $0! }
    }
}
