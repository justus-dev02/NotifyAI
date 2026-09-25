//
//  SpeakerDiarizer.swift
//  NotifyAI
//

import Accelerate
import AVFoundation
import Foundation

/// A time span attributed to one speaker.
struct SpeakerTurn: Equatable, Sendable {
    var start: TimeInterval
    var end: TimeInterval
    var speaker: Int
}

/// Experimental, fully local speaker diarization ("who spoke when").
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
/// than neural speaker embeddings, and the threshold has not been calibrated on real
/// recordings. The feature is therefore opt-in and labelled experimental in the UI.
struct SpeakerDiarizer: Sendable {
    struct Configuration: Sendable {
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
    func turns(forAudioAt url: URL) async throws -> [SpeakerTurn] {
        try await Task.detached(priority: .utility) {
            let samples = try Self.readMonoSamples(from: url)
            try Task.checkCancellation()
            return self.turns(for: samples)
        }.value
    }

    func turns(for samples: [Float]) -> [SpeakerTurn] {
        let frames = LogMelSpectrogram().frames(of: samples)
        guard !frames.isEmpty else { return [] }

        let voiced = voicedFrames(frames)
        let windows = embeddingWindows(frames: frames, voiced: voiced)
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
                updated.speaker = "Sprecher \(best.key + 1)"
            }
            return updated
        }
    }

    // MARK: - Steps

    private struct Window {
        let start: TimeInterval
        let end: TimeInterval
        let embedding: [Float]
    }

    /// Voice activity relative to the recording itself, which adapts to microphone gain:
    /// a frame is voiced when it is well above the noise floor (10th percentile of all
    /// frame energies) and not far below the loudest speech (95th percentile). Without the
    /// noise-floor condition, background noise in pauses counts as speech and windows at
    /// pauses form a spurious extra "speaker".
    private func voicedFrames(_ frames: [LogMelSpectrogram.Frame]) -> [Bool] {
        let energies = frames.map(\.energyDB).sorted()
        let noiseFloor = energies[Int(Double(energies.count - 1) * 0.10)]
        let loud = energies[Int(Double(energies.count - 1) * 0.95)]
        let threshold = max(loud - configuration.voiceActivityRangeDB, noiseFloor + configuration.noiseMarginDB)
        return frames.map { $0.energyDB > threshold && $0.energyDB > -70 }
    }

    private func embeddingWindows(frames: [LogMelSpectrogram.Frame], voiced: [Bool]) -> [Window] {
        let frameDuration = LogMelSpectrogram.frameDuration
        let framesPerWindow = Int(configuration.windowDuration / frameDuration)
        let totalDuration = Double(frames.count) * frameDuration
        let hop = max(configuration.minimumHop, totalDuration / Double(configuration.maximumWindows))
        let framesPerHop = max(1, Int(hop / frameDuration))

        var windows: [Window] = []
        var start = 0
        while start + framesPerWindow <= frames.count {
            let range = start..<(start + framesPerWindow)
            let voicedIndices = range.filter { voiced[$0] }
            // Only windows that are mostly speech describe a voice.
            if Double(voicedIndices.count) >= Double(framesPerWindow) * 0.6 {
                windows.append(Window(
                    start: Double(start) * frameDuration,
                    end: Double(range.upperBound) * frameDuration,
                    embedding: spectralShape(of: voicedIndices.map { frames[$0].logMel })
                ))
            }
            start += framesPerHop
        }
        return windows
    }

    private static let metric = AgglomerativeClustering.Metric.rootMeanSquare

    /// Average log-mel spectrum with its mean across bands removed (loudness invariant).
    private func spectralShape(of rows: [[Float]]) -> [Float] {
        var mean = [Float](repeating: 0, count: LogMelSpectrogram.melBandCount)
        for row in rows { mean = vDSP.add(mean, row) }
        mean = vDSP.divide(mean, Float(rows.count))
        return vDSP.add(-vDSP.mean(mean), mean)
    }

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

    // MARK: - Audio

    static func readMonoSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let targetFormat = AudioFormat.makeProcessingFormat()
        guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
            throw TranscriptionError.unreadableAudio
        }
        converter.downmix = true

        let blockSize: AVAudioFrameCount = 32_768
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: blockSize) else {
            throw TranscriptionError.unreadableAudio
        }
        let ratio = targetFormat.sampleRate / file.processingFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(blockSize) * ratio) + 1_024

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * ratio))
        var reachedEnd = false

        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else { break }
            var readError: (any Error)?
            let status = converter.convert(to: output, error: nil) { _, inputStatus in
                // `read` throws `eofErr` at the end instead of returning zero frames,
                // so the remaining length is checked first.
                let remaining = file.length - file.framePosition
                if reachedEnd || remaining <= 0 {
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inputBuffer, frameCount: AVAudioFrameCount(min(Int64(blockSize), remaining)))
                } catch {
                    readError = error
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inputBuffer.frameLength == 0 {
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inputBuffer
            }
            if let readError { throw readError }
            samples.append(contentsOf: output.monoSamples)
            if status == .endOfStream || status == .error { break }
        }
        return samples
    }
}
