//
//  TranscriptVerifier.swift
//  NotifyAIServices
//

import Accelerate
import Foundation
import NotifyAICore
import OSLog

/// Where the audio of a recording contains speech, in frames of 20 ms.
///
/// A frame counts as speech when it is clearly louder than the recording's own background:
/// the noise floor is the quiet end of the recording's levels (10th percentile), so a fan or
/// a humming room does not count as speech, while a quiet speaker in a quiet room does.
struct SpeechEvidence: Sendable {
    static let frameDuration: TimeInterval = 0.02
    /// Frames quieter than this RMS (about -48 dBFS) are never speech.
    static let absoluteThreshold: Float = 0.004
    /// A frame is speech when it is this many times louder than the noise floor.
    static let speechToNoiseRatio: Float = 3

    private let speech: [Bool]

    init(levels: [Float]) {
        guard !levels.isEmpty else {
            speech = []
            return
        }
        let sorted = levels.sorted()
        let noiseFloor = sorted[sorted.count / 10]
        let threshold = max(Self.absoluteThreshold, noiseFloor * Self.speechToNoiseRatio)
        speech = levels.map { $0 > threshold }
    }

    /// The RMS level of every 20 ms frame of 16 kHz mono samples.
    static func levels(of samples: [Float]) -> [Float] {
        let frameLength = Int(frameDuration * AudioFormat.sampleRate)
        return stride(from: 0, to: samples.count - frameLength + 1, by: frameLength).map { start in
            samples[start..<(start + frameLength)].withUnsafeBufferPointer { vDSP.rootMeanSquare($0) }
        }
    }

    /// Reads the file block by block; memory stays small even for hours of audio.
    static func analyze(fileAt url: URL) async throws -> Self {
        try await BackgroundWork.run(priority: .utility) {
            var levels: [Float] = []
            var carry: [Float] = []
            let frameLength = Int(frameDuration * AudioFormat.sampleRate)
            try await SpeakerDiarizer.forEachMonoBlock(in: url) { block, _ in
                carry += block
                let usable = carry.count - carry.count % frameLength
                levels += Self.levels(of: Array(carry[..<usable]))
                carry.removeFirst(usable)
            }
            return Self(levels: levels)
        }
    }

    /// The share of frames between `start` and `end` that contain speech (0…1).
    func speechFraction(from start: TimeInterval, to end: TimeInterval) -> Double {
        guard !speech.isEmpty else { return 0 }
        let first = max(0, min(speech.count - 1, Int(start / Self.frameDuration)))
        let last = max(first, min(speech.count - 1, Int(end / Self.frameDuration)))
        let frames = speech[first...last]
        return Double(frames.count { $0 }) / Double(frames.count)
    }
}

/// Removes transcript text that the audio does not support.
///
/// Speech recognizers, Whisper above all, produce text for audio that contains no speech:
/// in silence or background noise they emit the phrases most frequent in their training
/// data ("Vielen Dank.", "Untertitel im Auftrag des ZDF", "Thank you."), often again and
/// again. A segment is removed when
/// - its time span contains (almost) no speech, or
/// - it is such a typical phrase and its time span contains little speech, or
/// - the same text repeats at least three times in a row over little speech.
/// Real speech in a quiet room keeps its segments: they cover speech frames.
struct TranscriptVerifier: Sendable {
    /// Below this share of speech frames a segment is not backed by audio at all.
    var minimumSpeechFraction = 0.02
    /// Typical hallucinations and repetitions need at least this share to be kept.
    var minimumFractionForSuspiciousText = 0.15
    /// Identical segments in a row from this count on are suspicious.
    var suspiciousRepetitions = 3

    /// Phrases recognizers invent for silence, normalized (lowercase letters and spaces).
    static let typicalHallucinations: Set<String> = [
        "vielen dank", "danke", "danke schön", "dankeschön", "danke fürs zuschauen", "vielen dank fürs zuschauen",
        "vielen dank für ihre aufmerksamkeit", "tschüss", "bis zum nächsten mal", "bis dann", "das wars",
        "untertitel im auftrag des zdf", "untertitel im auftrag des zdf für funk", "untertitel der amara org community",
        "untertitelung des zdf", "musik", "applaus", "lachen",
        "thank you", "thanks", "thank you for watching", "thanks for watching", "bye", "you",
        "subtitles by the amara org community", "music", "applause",
    ]

    func verify(_ segments: [TranscriptSegment], against evidence: SpeechEvidence) -> [TranscriptSegment] {
        let fractions = segments.map { evidence.speechFraction(from: $0.start, to: $0.end) }
        let keys = segments.map { Self.normalized($0.text) }
        var removed = Set<Int>()

        for index in segments.indices {
            if fractions[index] < minimumSpeechFraction {
                removed.insert(index)
            } else if Self.typicalHallucinations.contains(keys[index]), fractions[index] < minimumFractionForSuspiciousText {
                removed.insert(index)
            }
        }

        // Runs of the same text: suspicious as a whole when the run is mostly not speech.
        var runStart = 0
        for index in segments.indices.dropFirst() + [segments.count] {
            guard index == segments.count || keys[index] != keys[runStart] else { continue }
            let run = runStart..<index
            if run.count >= suspiciousRepetitions {
                let average = run.map { fractions[$0] }.reduce(0, +) / Double(run.count)
                if average < minimumFractionForSuspiciousText {
                    removed.formUnion(run)
                }
            }
            runStart = index
        }

        if !removed.isEmpty {
            Logger.transcription.info("Removed \(removed.count, privacy: .public) of \(segments.count, privacy: .public) segments without speech in the audio")
        }
        return segments.indices.filter { !removed.contains($0) }.map { segments[$0] }
    }

    /// Analyses the audio file and verifies the segments against it. When the file cannot be
    /// read, the segments are kept: losing real text would be worse.
    /// - Throws: Only `CancellationError`.
    func verify(_ segments: [TranscriptSegment], audioAt url: URL) async throws -> [TranscriptSegment] {
        guard !segments.isEmpty else { return segments }
        do {
            let evidence = try await SpeechEvidence.analyze(fileAt: url)
            return verify(segments, against: evidence)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Logger.transcription.error("Verifying the transcript against the audio failed: \(error.localizedDescription, privacy: .public)")
            return segments
        }
    }

    /// Lowercase words separated by single spaces: punctuation separates words ("amara.org"
    /// becomes "amara org"), apostrophes do not ("das war's" becomes "das wars").
    static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .unicodeScalars
            .map { CharacterSet.letters.contains($0) ? String($0) : " " }
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
    }
}
