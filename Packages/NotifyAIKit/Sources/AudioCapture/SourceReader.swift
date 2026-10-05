//
//  SourceReader.swift
//  AudioCapture
//

import AVFoundation
import NotifyAICore

/// Audio a source lost before it reached the file.
struct SampleLosses {
    /// Dropped by the audio thread because the ring was full.
    var dropped = 0
    /// Lost because converting to 16 kHz failed.
    var failedConversion = 0
    /// The latest conversion error.
    var conversionError: String?

    var isEmpty: Bool { dropped == 0 && failedConversion == 0 }

    mutating func add(_ other: Self) {
        dropped += other.dropped
        failedConversion += other.failedConversion
        conversionError = other.conversionError ?? conversionError
    }
}

/// Converts one source from its native rate to 16 kHz mono with reused buffers.
struct SourceReader {
    let source: CaptureSource
    let converter: AVAudioConverter
    let inputBuffer: AVAudioPCMBuffer
    let outputBuffer: AVAudioPCMBuffer
    /// Samples lost to conversion errors since the last `takeLosses()`.
    private var failedConversion = 0
    private var conversionError: String?

    init(source: CaptureSource) throws {
        let outputFormat = AudioFormat.makeProcessingFormat()
        // The rings hold downmixed mono at the source's rate.
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: source.sampleRate,
            channels: 1,
            interleaved: false
        ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw CaptureError.unsupportedFormat
        }
        // A tenth of a second per conversion, matching the processing interval.
        let inputCapacity = AVAudioFrameCount(max(1_024, (source.sampleRate / 10).rounded(.up)))
        let outputCapacity = AVAudioFrameCount((Double(inputCapacity) * outputFormat.sampleRate / source.sampleRate).rounded(.up)) + 64
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputCapacity),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity)
        else {
            throw CaptureError.unsupportedFormat
        }
        self.source = source
        self.converter = converter
        self.inputBuffer = inputBuffer
        self.outputBuffer = outputBuffer
    }

    /// Converts everything in the ring and appends it to `output`.
    mutating func drain(into output: inout SampleFIFO) {
        guard let input = inputBuffer.floatChannelData?[0] else { return }
        while source.ring.availableToRead > 0 {
            let count = source.ring.read(into: input, maximumCount: Int(inputBuffer.frameCapacity))
            inputBuffer.frameLength = AVAudioFrameCount(count)
            if let error = convert(into: &output) {
                failedConversion += count
                conversionError = error
            }
        }
    }

    /// Losses since the last call: samples the audio thread dropped and samples that
    /// could not be converted.
    mutating func takeLosses() -> SampleLosses {
        let losses = SampleLosses(dropped: source.ring.takeDroppedSamples(), failedConversion: failedConversion, conversionError: conversionError)
        failedConversion = 0
        conversionError = nil
        return losses
    }

    /// - Returns: The error description if the conversion failed; the input is then lost.
    private func convert(into output: inout SampleFIFO) -> String? {
        outputBuffer.frameLength = 0
        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if didProvideInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        if status == .error {
            return conversionError?.localizedDescription ?? "AVAudioConverter status error"
        }
        guard outputBuffer.frameLength > 0, let samples = outputBuffer.floatChannelData?[0] else { return nil }
        output.append(UnsafeBufferPointer(start: samples, count: Int(outputBuffer.frameLength)))
        return nil
    }
}
