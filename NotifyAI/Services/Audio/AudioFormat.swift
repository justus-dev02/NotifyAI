//
//  AudioFormat.swift
//  NotifyAI
//

import AVFoundation

/// The canonical audio format used throughout the app.
///
/// Microphone input is converted once to 16 kHz mono, which is what both speech
/// engines expect. Recordings are stored as AAC in a CAF container: about 10× smaller
/// than PCM, and unlike M4A a CAF file stays readable if the app is killed mid-recording.
enum AudioFormat {
    static let sampleRate: Double = 16_000
    static let recordingFileExtension = "caf"

    /// Float32, mono, non-interleaved, 16 kHz.
    static func makeProcessingFormat() -> AVAudioFormat {
        // Creating a standard PCM format with valid parameters cannot fail.
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    static var recordingFileSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
    }
}

/// A block of mono samples at `AudioFormat.sampleRate`, positioned on the recording timeline.
struct AudioChunk: Sendable {
    let samples: [Float]
    /// Index of the first sample on the recording timeline.
    let startFrame: Int64

    var startTime: TimeInterval { Double(startFrame) / AudioFormat.sampleRate }
    var duration: TimeInterval { Double(samples.count) / AudioFormat.sampleRate }
    var endFrame: Int64 { startFrame + Int64(samples.count) }
}

extension AVAudioPCMBuffer {
    /// Samples of the first channel. Only valid for Float32 buffers.
    var monoSamples: [Float] {
        guard let channel = floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(frameLength)))
    }

    /// Creates a Float32 mono buffer containing `samples`.
    static func mono(_ samples: [Float], format: AVAudioFormat = AudioFormat.makeProcessingFormat()) -> AVAudioPCMBuffer? {
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
