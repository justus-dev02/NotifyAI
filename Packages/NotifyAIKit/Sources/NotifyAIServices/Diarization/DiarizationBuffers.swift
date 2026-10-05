//
//  DiarizationBuffers.swift
//  NotifyAIServices
//
//  Streaming helpers of the speaker detection: reading a file block by block, cutting it
//  into frames and accumulating the spectra of overlapping windows with little memory.
//

import Accelerate
import AVFoundation
import Foundation
import NotifyAICore

/// Decodes and converts an audio file to 16 kHz mono, one converter block at a time.
final class MonoFileReader {
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
struct WindowAccumulator {
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
