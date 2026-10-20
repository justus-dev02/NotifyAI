//
//  SpeechGateTests.swift
//  NotifyAITests
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
import Synchronization
import Testing

@Suite("Speech detection before Whisper")
struct SpeechDetectorTests {
    private struct ClassifierFailure: Error {}

    final class CallCounter: Sendable {
        private let calls = Mutex(0)
        var total: Int { calls.withLock { $0 } }
        func record() { calls.withLock { $0 += 1 } }
    }

    /// A detector whose classifier returns `confidence` and counts its calls.
    private func detector(confidence: Double, calls: CallCounter = CallCounter()) -> SpeechDetector {
        var detector = SpeechDetector()
        detector.classify = { _ in
            calls.record()
            return confidence
        }
        return detector
    }

    private var failingDetector: SpeechDetector {
        var detector = SpeechDetector()
        detector.classify = { _ in throw ClassifierFailure() }
        return detector
    }

    @Test("Silence is rejected without running the classifier")
    func silence() {
        let calls = CallCounter()
        let detector = detector(confidence: 1, calls: calls)
        #expect(!detector.containsSpeech(Signal.silence(seconds: 10)))
        #expect(calls.total == 0)
    }

    @Test("A click in silence is rejected without running the classifier")
    func click() {
        var samples = Signal.silence(seconds: 10)
        for index in 16_000..<16_640 {
            samples[index] = index.isMultiple(of: 2) ? 0.3 : -0.3
        }
        let calls = CallCounter()
        #expect(!detector(confidence: 1, calls: calls).containsSpeech(samples))
        #expect(calls.total == 0)
    }

    @Test("Audible audio is speech only when the classifier says so")
    func classifierDecides() {
        let noise = Signal.noise(seconds: 10, amplitude: 0.03)
        #expect(!detector(confidence: 0.02).containsSpeech(noise))
        #expect(!detector(confidence: 0.29).containsSpeech(noise))
        #expect(detector(confidence: 0.3).containsSpeech(noise))
        #expect(detector(confidence: 0.9).containsSpeech(noise))
    }

    @Test("Without the classifier, steady noise is rejected")
    func fallbackRejectsNoise() {
        #expect(!failingDetector.containsSpeech(Signal.noise(seconds: 10, amplitude: 0.03)))
    }

    @Test("Without the classifier, speech clearly above the noise floor is accepted")
    func fallbackAcceptsSpeech() {
        let samples = Signal.silence(seconds: 4) + Signal.voice(seconds: 2, frequency: 140, overtoneDecay: 0.7) + Signal.silence(seconds: 4)
        let noise = Signal.noise(seconds: 10, amplitude: 0.005)
        #expect(failingDetector.containsSpeech(zip(samples, noise).map(+)))
    }

    @Test("Apple's classifier finds no speech in noise, hum and short audio")
    func realClassifier() throws {
        #expect(try SpeechClassifier.speechConfidence(of: Signal.noise(seconds: 10, amplitude: 0.05)) < 0.3)
        let hum = (0..<160_000).map { Float(0.05 * sin(2 * Double.pi * 50 * Double($0) / Signal.sampleRate)) }
        #expect(try SpeechClassifier.speechConfidence(of: hum) < 0.3)
        // Shorter than one window: padded instead of producing no result.
        #expect(try SpeechClassifier.speechConfidence(of: Signal.noise(seconds: 0.4, amplitude: 0.05)) < 0.3)
        #expect(!SpeechDetector().containsSpeech(Signal.noise(seconds: 10, amplitude: 0.05)))
    }
}

@Suite("Whisper segment confidence")
struct WhisperSegmentConfidenceTests {
    @Test("Confident segments are kept")
    func confident() {
        #expect(WhisperRuntime.isReliable(compressionRatio: 1.3, averageLogProbability: -0.3, wordProbabilities: [0.9, 0.8, 0.95]))
        // Timestamps-only results carry no words.
        #expect(WhisperRuntime.isReliable(compressionRatio: 1.3, averageLogProbability: -0.3, wordProbabilities: []))
    }

    @Test("Repetitive text is dropped")
    func repetitive() {
        #expect(!WhisperRuntime.isReliable(compressionRatio: 2.5, averageLogProbability: -0.2, wordProbabilities: [0.9]))
    }

    @Test("A failed decoding is dropped")
    func lowLogProbability() {
        #expect(!WhisperRuntime.isReliable(compressionRatio: 1.2, averageLogProbability: -1.2, wordProbabilities: [0.9]))
    }

    @Test("Words the model does not believe are dropped")
    func lowWordProbability() {
        #expect(!WhisperRuntime.isReliable(compressionRatio: 1.2, averageLogProbability: -0.5, wordProbabilities: [0.2, 0.3, 0.5]))
        #expect(WhisperRuntime.isReliable(compressionRatio: 1.2, averageLogProbability: -0.5, wordProbabilities: [0.3, 0.5, 0.6]))
    }

    @Test("Blank tokens are suppressed")
    func suppressBlank() {
        #expect(WhisperRuntime.decodingOptions(language: .german).suppressBlank)
    }
}
