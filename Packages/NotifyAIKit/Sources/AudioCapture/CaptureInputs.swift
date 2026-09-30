//
//  CaptureInputs.swift
//  AudioCapture
//

import Accelerate
import AVFoundation

/// Where microphone and system audio sit in the input of a Core Audio aggregate device.
///
/// The aggregate delivers one buffer per input stream: first the streams of its clock
/// device (the microphone, or the output device when only system audio is recorded),
/// then the stream of the process tap.
public struct AggregateInputLayout: Sendable {
    public struct Source: Sendable {
        public let bufferIndex: Int
        /// Linear PCM Float32, interleaved (the virtual format of the aggregate's stream).
        public let streamFormat: AudioStreamBasicDescription

        public init(bufferIndex: Int, streamFormat: AudioStreamBasicDescription) {
            self.bufferIndex = bufferIndex
            self.streamFormat = streamFormat
        }
    }

    /// `nil` when only system audio is recorded.
    public let microphone: Source?
    public let system: Source

    public init(microphone: Source? = nil, system: Source) {
        self.microphone = microphone
        self.system = system
    }
}

/// One audio source as the real-time thread sees it: a ring buffer that receives the
/// source downmixed to mono at its native sample rate.
public struct CaptureSource: Sendable {
    /// Seconds of audio a ring can hold. The processing queue normally empties it every
    /// 100 ms; the reserve covers a disk that stalls for a few seconds (Time Machine,
    /// Spotlight) without losing audio.
    public static let bufferedSeconds: Double = 15

    public let ring: SampleRingBuffer
    public let sampleRate: Double
    public let channelCount: Int

    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = max(1, channelCount)
        ring = SampleRingBuffer(capacity: Int(sampleRate * Self.bufferedSeconds))
    }
}

/// Real-time side of a microphone recording through `AVAudioEngine`.
///
/// `process(_:)` runs on the engine's tap thread. It only downmixes into the ring buffer:
/// no allocation, no lock, no file access. Conversion, writing and streaming happen on the
/// capture processing queue (`AudioCaptureContext`).
public final class MicrophoneCaptureInput: Sendable {
    public let source: CaptureSource

    public init(format: AVAudioFormat) {
        source = CaptureSource(sampleRate: format.sampleRate, channelCount: Int(format.channelCount))
    }

    public func process(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = min(Int(buffer.format.channelCount), source.channelCount)
        guard frames > 0, channelCount > 0 else { return }

        if buffer.format.isInterleaved {
            AudioDownmix.write(interleaved: channels[0], channelCount: channelCount, frames: frames, to: source.ring)
        } else {
            AudioDownmix.write(planar: channels, channelCount: channelCount, frames: frames, to: source.ring)
        }
    }
}

/// Real-time side of a recording through a Core Audio aggregate device (process tap,
/// optionally with the microphone). `process(_:)` is the aggregate's I/O block.
///
/// A new input is created whenever the aggregate is rebuilt, so the layout never changes
/// while the I/O block runs and needs no synchronization.
public final class AggregateCaptureInput: Sendable {
    public let layout: AggregateInputLayout
    public let microphone: CaptureSource?
    public let system: CaptureSource

    public init(layout: AggregateInputLayout) {
        self.layout = layout
        microphone = layout.microphone.map {
            CaptureSource(sampleRate: $0.streamFormat.mSampleRate, channelCount: Int($0.streamFormat.mChannelsPerFrame))
        }
        system = CaptureSource(sampleRate: layout.system.streamFormat.mSampleRate, channelCount: Int(layout.system.streamFormat.mChannelsPerFrame))
    }

    /// Called on the aggregate's I/O thread with the input of all streams.
    public func process(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard layout.system.bufferIndex < buffers.count else { return }
        let systemBuffer = buffers[layout.system.bufferIndex]
        let systemFrames = Self.frameCount(of: systemBuffer, channelCount: self.system.channelCount)

        var microphoneBuffer: AudioBuffer?
        var microphoneFrames = 0
        if let microphone, let index = layout.microphone?.bufferIndex, index < buffers.count {
            microphoneBuffer = buffers[index]
            microphoneFrames = Self.frameCount(of: buffers[index], channelCount: microphone.channelCount)
        }

        // Both sources share the aggregate's clock and must stay aligned: when either ring
        // is full, the whole cycle is dropped for both.
        if let microphone, microphoneFrames > microphone.ring.freeSpace || systemFrames > self.system.ring.freeSpace {
            microphone.ring.recordDrop(microphoneFrames)
            self.system.ring.recordDrop(systemFrames)
            return
        }

        if let data = systemBuffer.mData, systemFrames > 0 {
            AudioDownmix.write(
                interleaved: data.assumingMemoryBound(to: Float.self),
                channelCount: self.system.channelCount,
                frames: systemFrames,
                to: self.system.ring
            )
        }
        if let microphone, let data = microphoneBuffer?.mData, microphoneFrames > 0 {
            AudioDownmix.write(
                interleaved: data.assumingMemoryBound(to: Float.self),
                channelCount: microphone.channelCount,
                frames: microphoneFrames,
                to: microphone.ring
            )
        }
    }

    private static func frameCount(of buffer: AudioBuffer, channelCount: Int) -> Int {
        Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * max(1, channelCount))
    }
}

/// Real-time safe downmixing into a ring buffer: the average of all channels, computed
/// with vDSP directly in the ring's storage.
public enum AudioDownmix {
    public static func write(interleaved samples: UnsafePointer<Float>, channelCount: Int, frames: Int, to ring: SampleRingBuffer) {
        ring.write(count: frames) { destination, offset in
            guard let output = destination.baseAddress else { return }
            let count = vDSP_Length(destination.count)
            let source = samples + offset * channelCount
            if channelCount == 1 {
                output.update(from: source, count: destination.count)
                return
            }
            var scale = 1 / Float(channelCount)
            vDSP_vsmul(source, channelCount, &scale, output, 1, count)
            for channel in 1..<channelCount {
                vDSP_vsma(source + channel, channelCount, &scale, output, 1, output, 1, count)
            }
        }
    }

    public static func write(planar channels: UnsafePointer<UnsafeMutablePointer<Float>>, channelCount: Int, frames: Int, to ring: SampleRingBuffer) {
        ring.write(count: frames) { destination, offset in
            guard let output = destination.baseAddress else { return }
            let count = vDSP_Length(destination.count)
            if channelCount == 1 {
                output.update(from: channels[0] + offset, count: destination.count)
                return
            }
            var scale = 1 / Float(channelCount)
            vDSP_vsmul(channels[0] + offset, 1, &scale, output, 1, count)
            for channel in 1..<channelCount {
                vDSP_vsma(channels[channel] + offset, 1, &scale, output, 1, output, 1, count)
            }
        }
    }
}
