//
//  SpeechDetector.swift
//  NotifyAITranscription
//

import AVFoundation
import NotifyAICore
import NotifyAISupport
import OSLog
import SoundAnalysis
import Synchronization

/// Decides whether audio contains speech before it is handed to Whisper.
///
/// Whisper always produces text: for silence and background noise it emits the phrases most
/// frequent in its training data ("Vielen Dank.", "Untertitel im Auftrag des ZDF"). Audio
/// without speech therefore must not reach it at all. The decision has three stages:
/// 1. Audio with less than `minimumSpeechDuration` above `SpeechEvidence.absoluteThreshold`
///    is silence; nothing else is analysed.
/// 2. Apple's on-device sound classifier rates the audio in windows of 1.5 s. The audio
///    contains speech when one window reaches `minimumConfidence`. Measured on this
///    classifier: silence, white noise up to -25 dBFS, mains hum and typing stay below 0.02;
///    speech stays above 0.5, also 30 dB quieter or 5 dB below the noise.
/// 3. If the classifier fails, the level decides: at least `minimumSpeechDuration` of frames
///    clearly above the audio's own noise floor (see `SpeechEvidence`).
package struct SpeechDetector: Sendable {
    /// Audio needs at least this much audible (stage 1) or salient (stage 3) signal.
    var minimumSpeechDuration: TimeInterval = 0.3
    /// Speech confidence of the classifier from which audio contains speech.
    var minimumConfidence = 0.3
    /// The highest speech confidence (0…1) the classifier finds in the samples.
    var classify: @Sendable ([Float]) throws -> Double = SpeechClassifier.speechConfidence(of:)

    func containsSpeech(_ samples: [Float]) -> Bool {
        let levels = SpeechEvidence.levels(of: samples)
        let audibleFrames = levels.count { $0 > SpeechEvidence.absoluteThreshold }
        guard Double(audibleFrames) * SpeechEvidence.frameDuration >= minimumSpeechDuration else {
            return false
        }
        do {
            return try classify(samples) >= minimumConfidence
        } catch {
            Logger.transcription.error("Speech classification failed, deciding by level: \(error.localizedDescription, privacy: .public)")
            return SpeechEvidence(levels: levels).speechDuration >= minimumSpeechDuration
        }
    }
}

/// Speech detection with the built-in classifier of SoundAnalysis.
enum SpeechClassifier {
    static let windowDuration: TimeInterval = 1.5
    /// Classes of the classifier that are spoken words.
    static let speechLabels: Set<String> = ["speech", "shout", "yell", "whispering"]

    /// The highest confidence of a speech class over all windows of the samples (0…1).
    static func speechConfidence(of samples: [Float]) throws -> Double {
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: windowDuration, preferredTimescale: CMTimeScale(AudioFormat.sampleRate))
        request.overlapFactor = 0.5

        // Audio shorter than a window yields no result, so it is padded with silence.
        let windowSamples = Int(windowDuration * AudioFormat.sampleRate)
        let padded = samples.count < windowSamples
            ? samples + [Float](repeating: 0, count: windowSamples - samples.count)
            : samples
        guard let buffer = AVAudioPCMBuffer.mono(padded) else {
            throw TranscriptionError.unreadableAudio
        }

        let observer = SpeechObserver()
        let analyzer = SNAudioStreamAnalyzer(format: buffer.format)
        try analyzer.add(request, withObserver: observer)
        analyzer.analyze(buffer, atAudioFramePosition: 0)
        // Returns once every result has been delivered to the observer.
        analyzer.completeAnalysis()
        return try observer.result()
    }
}

/// Collects the highest speech confidence of a classification.
private final class SpeechObserver: NSObject, SNResultsObserving, Sendable {
    private struct State {
        var confidence = 0.0
        var error: (any Error)?
    }

    private let state = Mutex(State())

    func result() throws -> Double {
        try state.withLock { state in
            if let error = state.error {
                throw error
            }
            return state.confidence
        }
    }

    func request(_ request: any SNRequest, didProduce result: any SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let confidence = SpeechClassifier.speechLabels
            .compactMap { result.classification(forIdentifier: $0)?.confidence }
            .max() ?? 0
        state.withLock { $0.confidence = max($0.confidence, confidence) }
    }

    func request(_ request: any SNRequest, didFailWithError error: any Error) {
        state.withLock { $0.error = error }
    }
}
