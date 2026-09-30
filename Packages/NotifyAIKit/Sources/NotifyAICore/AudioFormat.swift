//
//  AudioFormat.swift
//  NotifyAICore
//

import AVFoundation

/// The canonical audio format used throughout the app.
///
/// Microphone input is converted once to 16 kHz mono, which is what both speech
/// engines expect. Recordings are stored as AAC in a CAF container: about 10× smaller
/// than PCM, and unlike M4A a CAF file stays readable if the app is killed mid-recording.
public enum AudioFormat {
    public static let sampleRate: Double = 16_000
    public static let recordingFileExtension = "caf"

    /// Float32, mono, non-interleaved, 16 kHz.
    public static func makeProcessingFormat() -> AVAudioFormat {
        // Creating a standard PCM format with valid parameters cannot fail.
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    public static var recordingFileSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
    }
}

/// A block of mono samples at `AudioFormat.sampleRate`, positioned on the recording timeline.
public struct AudioChunk: Sendable {
    public let samples: [Float]
    /// Index of the first sample on the recording timeline.
    public let startFrame: Int64

    public var startTime: TimeInterval { Double(startFrame) / AudioFormat.sampleRate }
    public var duration: TimeInterval { Double(samples.count) / AudioFormat.sampleRate }
    public var endFrame: Int64 { startFrame + Int64(samples.count) }

    public init(samples: [Float], startFrame: Int64) {
        self.samples = samples
        self.startFrame = startFrame
    }
}

extension AVAudioPCMBuffer {
    /// Samples of the first channel. Only valid for Float32 buffers.
    public var monoSamples: [Float] {
        guard let channel = floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(frameLength)))
    }

    /// Creates a Float32 mono buffer containing `samples`.
    public static func mono(_ samples: [Float], format: AVAudioFormat = AudioFormat.makeProcessingFormat()) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))),
              let channel = buffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: samples.count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}
