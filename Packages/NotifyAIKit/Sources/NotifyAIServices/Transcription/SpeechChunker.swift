//
//  SpeechChunker.swift
//  NotifyAIServices
//

import Accelerate
import Foundation
import NotifyAICore

/// Splits a continuous audio stream into chunks for Whisper.
///
/// Whisper works on windows of at most 30 s. Cutting at a fixed interval would split
/// words, so the chunker waits for a short pause once a chunk has a minimum length and
/// only cuts hard (at the quietest moment) when the maximum length is reached. Chunks
/// that are practically silent are dropped: feeding silence to Whisper is the main cause
/// of hallucinated sentences. The speech/noise estimate is only used to find pauses and
/// never decides whether audio is discarded, so loud rooms cannot swallow speech.
///
/// Each sample is analysed once, so the cost is linear in the recording length.
struct SpeechChunker {
    struct Configuration: Sendable {
        var minimumChunkDuration: TimeInterval = 6
        var maximumChunkDuration: TimeInterval = 25
        /// Length of silence that counts as a pause between phrases.
        var pauseDuration: TimeInterval = 0.5
        /// Analysis frame length.
        var frameDuration: TimeInterval = 0.02
        /// Frames quieter than this RMS (about -48 dBFS) are silent, regardless of the noise
        /// floor. A chunk is only dropped if every frame is below it.
        var absoluteSilenceThreshold: Float = 0.004
        /// A frame is speech when it is this many times louder than the noise floor.
        var speechToNoiseRatio: Float = 3
    }

    private let configuration: Configuration
    private let frameLength: Int

    private var samples: [Float] = []
    private var startFrame: Int64 = 0
    private var frameLevels: [Float] = []
    private var pendingFrameSamples: [Float] = []
    private var noiseFloor: Float = 0.01

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.frameLength = max(1, Int(configuration.frameDuration * AudioFormat.sampleRate))
    }

    /// Appends audio and returns every chunk that is complete.
    mutating func append(_ chunk: AudioChunk) -> [AudioChunk] {
        if samples.isEmpty {
            startFrame = chunk.startFrame
        }
        samples.append(contentsOf: chunk.samples)
        analyzeFrames(of: chunk.samples)

        var completed: [AudioChunk] = []
        while let cut = nextCutIndex() {
            if let emitted = emitChunk(upTo: cut) {
                completed.append(emitted)
            }
        }
        return completed
    }

    /// Returns the remaining audio as a final chunk, if it contains speech.
    mutating func flush() -> AudioChunk? {
        guard !samples.isEmpty else { return nil }
        return emitChunk(upTo: samples.count)
    }

    // MARK: - Private

    private var bufferedDuration: TimeInterval {
        Double(samples.count) / AudioFormat.sampleRate
    }

    private mutating func analyzeFrames(of newSamples: [Float]) {
        pendingFrameSamples.append(contentsOf: newSamples)
        var offset = 0
        while pendingFrameSamples.count - offset >= frameLength {
            let level = pendingFrameSamples[offset..<(offset + frameLength)].withUnsafeBufferPointer {
                vDSP.rootMeanSquare($0)
            }
            frameLevels.append(level)
            updateNoiseFloor(with: level)
            offset += frameLength
        }
        pendingFrameSamples.removeFirst(offset)
    }

    /// Tracks the background noise: follows quiet frames quickly, loud frames very slowly.
    private mutating func updateNoiseFloor(with level: Float) {
        if level < noiseFloor {
            noiseFloor = noiseFloor * 0.9 + level * 0.1
        } else {
            noiseFloor = noiseFloor * 0.999 + level * 0.001
        }
    }

    private func isSpeech(_ level: Float) -> Bool {
        level > configuration.absoluteSilenceThreshold && level > noiseFloor * configuration.speechToNoiseRatio
    }

    private func isSilent(_ level: Float) -> Bool {
        !isSpeech(level)
    }

    /// Sample index at which the buffer should be cut, or `nil` to keep buffering.
    private func nextCutIndex() -> Int? {
        let framesPerPause = max(1, Int(configuration.pauseDuration / configuration.frameDuration))

        if bufferedDuration >= configuration.minimumChunkDuration, frameLevels.count >= framesPerPause {
            let trailing = frameLevels.suffix(framesPerPause)
            if trailing.allSatisfy(isSilent) {
                // Cut in the middle of the pause so neither chunk loses a word boundary.
                let pauseStartFrame = frameLevels.count - framesPerPause
                return min(samples.count, (pauseStartFrame + framesPerPause / 2) * frameLength)
            }
        }

        if bufferedDuration >= configuration.maximumChunkDuration {
            return quietestCutIndex()
        }
        return nil
    }

    /// The quietest frame in the last few seconds; used when nobody pauses for a long time.
    private func quietestCutIndex() -> Int {
        let searchFrames = Int(3 / configuration.frameDuration)
        let lowerBound = max(0, frameLevels.count - searchFrames)
        let window = frameLevels[lowerBound...]
        let quietest = window.indices.min { frameLevels[$0] < frameLevels[$1] } ?? frameLevels.count - 1
        return min(samples.count, max(frameLength, (quietest + 1) * frameLength))
    }

    private mutating func emitChunk(upTo cut: Int) -> AudioChunk? {
        let chunkSamples = Array(samples[..<cut])
        let chunkFrames = min(frameLevels.count, cut / frameLength)
        let isAudible = chunkFrames == 0
            ? chunkSamples.contains { abs($0) > configuration.absoluteSilenceThreshold }
            : frameLevels[..<chunkFrames].contains { $0 > configuration.absoluteSilenceThreshold }
        let chunk = AudioChunk(samples: chunkSamples, startFrame: startFrame)

        samples.removeFirst(cut)
        frameLevels.removeFirst(chunkFrames)
        startFrame += Int64(cut)

        return isAudible ? chunk : nil
    }
}
