//
//  MonoAudioFile.swift
//  NotifyAIAudio
//

import AVFoundation
import Foundation
import NotifyAICore
import NotifyAISupport

/// Reads audio files as 16 kHz mono samples, the format speech recognition, speaker detection
/// and the transcript check work with.
package enum MonoAudioFile {
    /// Reads a whole file into memory. Only for short audio; long files use `forEachBlock`.
    static func readSamples(from url: URL) throws -> [Float] {
        let reader = try MonoFileReader(url: url)
        var samples: [Float] = []
        while let block = try reader.next() {
            samples.append(contentsOf: block)
        }
        return samples
    }

    /// Streams a file as 16 kHz mono blocks of about one minute (3.8 MB). Between blocks the
    /// work pauses while the device is hot, and cancellation is honored.
    package static func forEachBlock(
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

/// An audio file that cannot be decoded.
enum AudioFileError: LocalizedError, Equatable {
    case unreadable

    var errorDescription: String? {
        String(localized: "Die Audiodatei konnte nicht gelesen werden.", bundle: .module)
    }
}

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

    package init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: blockSize)
        else {
            throw AudioFileError.unreadable
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
