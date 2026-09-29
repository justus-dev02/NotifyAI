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
    ///
    /// The file is streamed twice instead of being loaded: a four-hour recording would need
    /// about 920 MB as samples. Pass 1 collects only the energy of every 10 ms frame (4 bytes
    /// per frame, about 6 MB for four hours) to find the voice-activity threshold. Pass 2
    /// computes the spectra one-minute block by block and adds each voiced frame to the
    /// windows it belongs to. Peak memory for four hours is about 15 MB (energies, voice
    /// flags and one block) instead of 920 MB. Between blocks the work pauses while the
    /// device is hot.
    func turns(forAudioAt url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [SpeakerTurn] {
        try await Task.detached(priority: .utility) {
            let spectrogram = LogMelSpectrogram()

            // Pass 1: frame energies.
            var energies: [Float] = []
            var framer = FrameBuffer()
            try await Self.forEachMonoBlock(in: url) { block, fraction in
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
            try await Self.forEachMonoBlock(in: url) { block, fraction in
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
        }.value
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
                updated.speaker = "Sprecher \(best.key + 1)"
            }
            return updated
        }
    }

    // MARK: - Steps

    fileprivate struct Window {
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

    // MARK: - Audio

    /// Reads a whole file into memory. Only for short audio; long files use `forEachMonoBlock`.
    static func readMonoSamples(from url: URL) throws -> [Float] {
        let reader = try MonoFileReader(url: url)
        var samples: [Float] = []
        while let block = try reader.next() {
            samples.append(contentsOf: block)
        }
        return samples
    }

    /// Streams a file as 16 kHz mono blocks of about one minute (3.8 MB). Between blocks the
    /// work pauses while the device is hot, and cancellation is honored.
    static func forEachMonoBlock(
        in url: URL,
        blockDuration: TimeInterval = 60,
        _ body: ([Float], _ fraction: Double) async throws -> Void
    ) async throws {
        let reader = try MonoFileReader(url: url)
        let blockSamples = Int(blockDuration * AudioFormat.sampleRate)
        var block: [Float] = []
        block.reserveCapacity(blockSamples)
        while let piece = try reader.next() {
            block.append(contentsOf: piece)
            if block.count >= blockSamples {
                try await body(block, reader.fraction)
                block.removeAll(keepingCapacity: true)
                try Task.checkCancellation()
                await DeviceLoad.waitWhileHot()
            }
        }
        if !block.isEmpty {
            try await body(block, 1)
        }
    }
}

// MARK: - Streaming helpers

/// Decodes and converts an audio file to 16 kHz mono, one converter block at a time.
private final class MonoFileReader {
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let inputBuffer: AVAudioPCMBuffer
    private let targetFormat = AudioFormat.makeProcessingFormat()
    private let outputCapacity: AVAudioFrameCount
    private let blockSize: AVAudioFrameCount = 32_768
    private var reachedEnd = false
    private var finished = false

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: blockSize)
        else {
            throw TranscriptionError.unreadableAudio
        }
        converter.downmix = true
        self.converter = converter
        self.inputBuffer = inputBuffer
        let ratio = targetFormat.sampleRate / file.processingFormat.sampleRate
        outputCapacity = AVAudioFrameCount(Double(blockSize) * ratio) + 1_024
    }

    /// Share of the file read so far.
    var fraction: Double {
        file.length > 0 ? min(1, Double(file.framePosition) / Double(file.length)) : 1
    }

    /// The next converted samples, or `nil` at the end of the file.
    func next() throws -> [Float]? {
        guard !finished, let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else { return nil }
        var readError: (any Error)?
        let status = converter.convert(to: output, error: nil) { [self] _, inputStatus in
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
        if status == .endOfStream || status == .error {
            finished = true
        }
        let samples = output.monoSamples
        return samples.isEmpty && finished ? nil : samples
    }
}

/// Collects samples across block boundaries and hands out slices that contain whole
/// spectrogram frames. Frame `n` always starts at sample `n × hop`, exactly as if the
/// whole file had been processed at once.
struct FrameBuffer {
    private var samples: [Float] = []

    mutating func append(_ block: [Float]) {
        samples.append(contentsOf: block)
    }

    /// Samples covering all complete frames that are available, or `nil` if there are none.
    /// The samples still needed for later frames stay in the buffer.
    mutating func nextFrames() -> [Float]? {
        let frameLength = LogMelSpectrogram.frameLength
        let hop = LogMelSpectrogram.hopLength
        guard samples.count >= frameLength else { return nil }
        let frameCount = (samples.count - frameLength) / hop + 1
        let slice = Array(samples[0..<((frameCount - 1) * hop + frameLength)])
        samples.removeFirst(frameCount * hop)
        return slice
    }
}

/// Sums the log-mel spectra of voiced frames per analysis window.
///
/// Windows of `windowDuration` start every `hop`; a frame belongs to every window that
/// covers it. Only the sums are kept (24 values per window, at most `maximumWindows`), so
/// memory does not grow with the recording length.
private struct WindowAccumulator {
    private let framesPerWindow: Int
    private let framesPerHop: Int
    private let windowCount: Int
    private var sums: [Float]
    private var counts: [Int]

    init(frameCount: Int, configuration: SpeakerDiarizer.Configuration) {
        let frameDuration = LogMelSpectrogram.frameDuration
        framesPerWindow = Int(configuration.windowDuration / frameDuration)
        let totalDuration = Double(frameCount) * frameDuration
        let hop = max(configuration.minimumHop, totalDuration / Double(configuration.maximumWindows))
        framesPerHop = max(1, Int(hop / frameDuration))
        windowCount = frameCount >= framesPerWindow ? (frameCount - framesPerWindow) / framesPerHop + 1 : 0
        sums = [Float](repeating: 0, count: windowCount * LogMelSpectrogram.melBandCount)
        counts = [Int](repeating: 0, count: windowCount)
    }

    mutating func add(_ logMel: [Float], at frame: Int) {
        guard windowCount > 0 else { return }
        let bands = LogMelSpectrogram.melBandCount
        // Windows w with w × hop ≤ frame < w × hop + framesPerWindow.
        let first = max(0, (frame - framesPerWindow) / framesPerHop + 1)
        let last = min(windowCount - 1, frame / framesPerHop)
        guard first <= last else { return }
        for window in first...last where window * framesPerHop + framesPerWindow > frame {
            let offset = window * bands
            for band in 0..<bands {
                sums[offset + band] += logMel[band]
            }
            counts[window] += 1
        }
    }

    /// Windows that are mostly speech, with the loudness-invariant spectral shape as embedding.
    func windows() -> [SpeakerDiarizer.Window] {
        let bands = LogMelSpectrogram.melBandCount
        let frameDuration = LogMelSpectrogram.frameDuration
        return (0..<windowCount).compactMap { window in
            // Only windows that are mostly speech describe a voice.
            guard Double(counts[window]) >= Double(framesPerWindow) * 0.6 else { return nil }
            let offset = window * bands
            let mean = vDSP.divide(Array(sums[offset..<(offset + bands)]), Float(counts[window]))
            let start = window * framesPerHop
            return SpeakerDiarizer.Window(
                start: Double(start) * frameDuration,
                end: Double(start + framesPerWindow) * frameDuration,
                // Average log-mel spectrum with its mean across bands removed (loudness invariant).
                embedding: vDSP.add(-vDSP.mean(mean), mean)
            )
        }
    }
}
