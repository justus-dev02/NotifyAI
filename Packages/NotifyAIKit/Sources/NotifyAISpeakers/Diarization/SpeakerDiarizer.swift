//
//  SpeakerDiarizer.swift
//  NotifyAISpeakers
//

import Accelerate
import AVFoundation
import Foundation
import NotifyAIAudio
import NotifyAICore
import NotifyAISupport

/// A time span attributed to one speaker.
struct SpeakerTurn: Equatable, Sendable {
    var start: TimeInterval
    var end: TimeInterval
    var speaker: Int
}

/// Who spoke when in an audio file.
package struct Diarization: Equatable, Sendable {
    /// Chronological turns. The simple diarizer returns none for a single voice; the neural
    /// one returns them for a single voice too, so that voice can still be recognized.
    var turns: [SpeakerTurn]
    /// Voice print per speaker (index of `SpeakerTurn.speaker`), L2-normalized. Only neural
    /// diarization produces them; they recognize a voice in later recordings.
    package var voicePrints: [Int: [Float]] = [:]

    /// Seconds of speech per voice.
    package var speechPerVoice: [Int: TimeInterval] {
        turns.reduce(into: [:]) { result, turn in
            result[turn.speaker, default: 0] += turn.end - turn.start
        }
    }
}

/// Finds who spoke when in an audio file. Implemented by `NeuralSpeakerDiarizer` and the
/// simple `SpeakerDiarizer`; `SpeakerDetection` picks one, the pipeline's step and the tests
/// depend on this protocol.
package protocol SpeakerDiarizing: Sendable {
    func diarize(audioAt url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Diarization
}

/// Simple, fully local speaker diarization ("who spoke when") without a model download. Used
/// when the neural speaker model is not installed.
///
/// Pipeline:
/// 1. Log-mel spectrogram (25 ms frames), energy-based voice activity detection.
/// 2. One embedding per 1.5 s window: the average log-mel spectrum of the voiced frames
///    minus its mean across bands. This describes the *shape* of the voice spectrum and
///    is independent of loudness.
/// 3. Average-linkage clustering on the root-mean-square difference of those shapes
///    (natural-log units, 1.0 ≈ 4.3 dB). The distance keeps its absolute scale on
///    purpose: normalizing embeddings per recording would inflate the small variations
///    of a single voice and split one speaker into several.
/// 4. Tiny clusters are folded into the closest large one, window labels are median
///    smoothed and merged into speaker turns.
///
/// Spectral-shape embeddings separate clearly different voices but are far less robust
/// than neural speaker embeddings (`NeuralSpeakerDiarizer`), and they cannot recognize a
/// voice in another recording.
package struct SpeakerDiarizer: SpeakerDiarizing {
    package func diarize(audioAt url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Diarization {
        Diarization(turns: try await turns(forAudioAt: url, progress: progress))
    }

    package struct Configuration: Sendable {
        var windowDuration: TimeInterval = 1.5
        var minimumHop: TimeInterval = 0.75
        /// Upper bound for the number of windows; keeps clustering at O(n²) with small n.
        var maximumWindows = 1_600
        /// Average RMS spectral-shape difference (log units) below which windows are merged.
        var distanceThreshold: Float = 0.8
        var maximumSpeakers = 6
        /// Clusters with less speech than this share are merged into their nearest neighbour.
        var minimumClusterShare = 0.05
        /// Frames quieter than the loudest frames minus this many dB count as silence.
        var voiceActivityRangeDB: Float = 35
        /// Frames must be at least this many dB above the estimated noise floor.
        var noiseMarginDB: Float = 6
    }

    var configuration = Configuration()

    /// Diarizes an audio file. Returns turns in chronological order, or an empty array
    /// when only one speaker (or no speech) was found.
    ///
    /// The file is streamed twice instead of being loaded: a four-hour recording would need
    /// about 920 MB as samples. Pass 1 collects only the energy of every 10 ms frame (4 bytes
    /// per frame, about 6 MB for four hours) to find the voice-activity threshold. Pass 2
    /// computes the spectra one-minute block by block and adds each voiced frame to the
    /// windows it belongs to. Peak memory for four hours is about 15 MB (energies, voice
    /// flags and one block) instead of 920 MB. Between blocks the work pauses while the
    /// device is hot. Cancelling the calling job stops it after the current block.
    func turns(forAudioAt url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [SpeakerTurn] {
        try await BackgroundWork.run(priority: .utility) {
            let spectrogram = LogMelSpectrogram()

            // Pass 1: frame energies.
            var energies: [Float] = []
            var framer = FrameBuffer()
            try await MonoAudioFile.forEachBlock(in: url) { block, fraction in
                framer.append(block)
                while let slice = framer.nextFrames() {
                    energies += LogMelSpectrogram.energiesDB(of: slice)
                }
                progress(0.4 * fraction)
            }
            guard !energies.isEmpty else { return [] }

            // Pass 2: spectra of voiced frames, accumulated per window.
            let voiced = self.voicedFrames(energies: energies)
            var accumulator = WindowAccumulator(frameCount: energies.count, configuration: self.configuration)
            framer = FrameBuffer()
            var frameIndex = 0
            try await MonoAudioFile.forEachBlock(in: url) { block, fraction in
                framer.append(block)
                while let slice = framer.nextFrames() {
                    for frame in spectrogram.frames(of: slice) where frameIndex < voiced.count {
                        if voiced[frameIndex] {
                            accumulator.add(frame.logMel, at: frameIndex)
                        }
                        frameIndex += 1
                    }
                }
                progress(0.4 + 0.5 * fraction)
            }
            try Task.checkCancellation()
            let turns = self.turns(from: accumulator.windows())
            progress(1)
            return turns
        }
    }

    /// Diarizes samples that are already in memory (short audio, tests).
    func turns(for samples: [Float]) -> [SpeakerTurn] {
        let frames = LogMelSpectrogram().frames(of: samples)
        guard !frames.isEmpty else { return [] }
        let voiced = voicedFrames(energies: frames.map(\.energyDB))
        var accumulator = WindowAccumulator(frameCount: frames.count, configuration: configuration)
        for (index, frame) in frames.enumerated() where voiced[index] {
            accumulator.add(frame.logMel, at: index)
        }
        return turns(from: accumulator.windows())
    }

    private func turns(from windows: [Window]) -> [SpeakerTurn] {
        guard windows.count >= 2 else { return [] }

        var labels = AgglomerativeClustering.cluster(
            windows.map(\.embedding),
            metric: Self.metric,
            threshold: configuration.distanceThreshold,
            maximumClusters: configuration.maximumSpeakers
        )
        labels = foldingSmallClusters(labels: labels, embeddings: windows.map(\.embedding))
        guard Set(labels).count >= 2 else { return [] }
        labels = medianSmoothed(labels)

        return makeTurns(windows: windows, labels: labels)
    }

    /// Assigns each segment the speaker with the largest time overlap.
    static func assignSpeakers(_ turns: [SpeakerTurn], to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !turns.isEmpty else { return segments }
        return segments.map { segment in
            var overlapBySpeaker: [Int: TimeInterval] = [:]
            for turn in turns where turn.end > segment.start && turn.start < segment.end {
                overlapBySpeaker[turn.speaker, default: 0] += min(turn.end, segment.end) - max(turn.start, segment.start)
            }
            var updated = segment
            if let best = overlapBySpeaker.max(by: { $0.value < $1.value }), best.value > 0.1 {
                updated.speaker = SpeakerLabels.detected(best.key + 1)
            }
            return updated
        }
    }

    // MARK: - Steps

    struct Window {
        let start: TimeInterval
        let end: TimeInterval
        let embedding: [Float]
    }

    /// Voice activity relative to the recording itself, which adapts to microphone gain:
    /// a frame is voiced when it is well above the noise floor (10th percentile of all
    /// frame energies) and not far below the loudest speech (95th percentile). Without the
    /// noise-floor condition, background noise in pauses counts as speech and windows at
    /// pauses form a spurious extra "speaker".
    private func voicedFrames(energies: [Float]) -> [Bool] {
        let sorted = energies.sorted()
        let noiseFloor = sorted[Int(Double(sorted.count - 1) * 0.10)]
        let loud = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let threshold = max(loud - configuration.voiceActivityRangeDB, noiseFloor + configuration.noiseMarginDB)
        return energies.map { $0 > threshold && $0 > -70 }
    }

    private static let metric = AgglomerativeClustering.Metric.rootMeanSquare

    private func foldingSmallClusters(labels: [Int], embeddings: [[Float]]) -> [Int] {
        let clusterIDs = Set(labels)
        guard clusterIDs.count > 1 else { return labels }

        let minimumSize = max(2, Int(Double(labels.count) * configuration.minimumClusterShare))
        let sizes = Dictionary(grouping: labels.indices, by: { labels[$0] }).mapValues(\.count)
        let largeClusters = clusterIDs.filter { sizes[$0, default: 0] >= minimumSize }
        guard !largeClusters.isEmpty else { return labels }

        let centroids = Dictionary(uniqueKeysWithValues: largeClusters.map { cluster in
            let members = labels.indices.filter { labels[$0] == cluster }
            var sum = [Float](repeating: 0, count: embeddings[0].count)
            for member in members { sum = vDSP.add(sum, embeddings[member]) }
            return (cluster, vDSP.divide(sum, Float(members.count)))
        })

        return labels.indices.map { index in
            let label = labels[index]
            if largeClusters.contains(label) { return label }
            return centroids.min {
                Self.metric.distance(embeddings[index], $0.value) < Self.metric.distance(embeddings[index], $1.value)
            }?.key ?? label
        }
    }

    /// Removes single-window flips between speakers, which are mostly noise.
    private func medianSmoothed(_ labels: [Int]) -> [Int] {
        guard labels.count >= 3 else { return labels }
        var smoothed = labels
        for index in 1..<(labels.count - 1) where labels[index - 1] == labels[index + 1] {
            smoothed[index] = labels[index - 1]
        }
        return smoothed
    }

    /// Merges consecutive windows of the same speaker and numbers speakers by first appearance.
    private func makeTurns(windows: [Window], labels: [Int]) -> [SpeakerTurn] {
        var speakerNumbers: [Int: Int] = [:]
        var turns: [SpeakerTurn] = []
        for (window, label) in zip(windows, labels) {
            let speaker = speakerNumbers[label] ?? {
                let number = speakerNumbers.count
                speakerNumbers[label] = number
                return number
            }()
            if var last = turns.last, last.speaker == speaker, window.start <= last.end + 1 {
                last.end = window.end
                turns[turns.count - 1] = last
            } else {
                // Overlapping windows: the new turn starts where the previous one ends.
                let start = max(window.start, turns.last?.end ?? 0)
                turns.append(SpeakerTurn(start: start, end: window.end, speaker: speaker))
            }
        }
        return turns
    }
}
