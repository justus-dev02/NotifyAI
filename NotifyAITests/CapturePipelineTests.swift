//
//  CapturePipelineTests.swift
//  NotifyAITests
//
//  The decoupled capture path: lock-free rings on the audio threads, conversion, mixing and
//  writing on the processing queue. Includes an end-to-end test through a real CAF file and
//  stress tests for device changes, a failing disk and a stalled consumer.
//

@testable import AudioCapture
import AVFoundation
import Foundation
@testable import NotifyAI
import NotifyAICore
import Synchronization
import Testing

// MARK: - Test doubles

/// Counts written frames in memory; optionally fails after a number of writes (full disk).
final class MemorySink: RecordingSink, @unchecked Sendable {
    private let lock = Mutex<(frames: Int, writes: Int)>((0, 0))
    let failAfterWrites: Int?

    init(failAfterWrites: Int? = nil) {
        self.failAfterWrites = failAfterWrites
    }

    var frames: Int { lock.withLock { $0.frames } }

    func write(from buffer: AVAudioPCMBuffer) throws {
        try lock.withLock { state in
            if let failAfterWrites, state.writes >= failAfterWrites {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            state.writes += 1
            state.frames += Int(buffer.frameLength)
        }
    }

    func close() {}
}

/// A disk that stalls: every write waits until `release()` is called.
final class StallingSink: RecordingSink, Sendable {
    private let released = Mutex(false)
    private let writing = Mutex(false)
    private let frames = Mutex(0)

    /// Whether a write is currently waiting for the disk.
    var isWriting: Bool { writing.withLock { $0 } }
    var writtenFrames: Int { frames.withLock { $0 } }

    func release() {
        released.withLock { $0 = true }
    }

    func write(from buffer: AVAudioPCMBuffer) throws {
        writing.withLock { $0 = true }
        while !released.withLock({ $0 }) {
            Thread.sleep(forTimeInterval: 0.005)
        }
        writing.withLock { $0 = false }
        frames.withLock { $0 += Int(buffer.frameLength) }
    }

    func close() {}
}

/// Synthetic device input.
enum DeviceSignal {
    /// A non-interleaved Float32 buffer with a sine in every channel.
    static func buffer(frequency: Double, rate: Double, channels: AVAudioChannelCount, frames: Int, startFrame: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(channels) {
            let data = buffer.floatChannelData![channel]
            for frame in 0..<frames {
                data[frame] = 0.3 * Float(sin(2 * .pi * frequency * Double(startFrame + frame) / rate))
            }
        }
        return buffer
    }

    /// Feeds `seconds` of a sine to a microphone input like an engine tap would.
    static func feed(_ input: MicrophoneCaptureInput, frequency: Double, seconds: Double, rate: Double, channels: AVAudioChannelCount) {
        let total = Int(seconds * rate)
        for start in stride(from: 0, to: total, by: 1_024) {
            input.process(buffer(frequency: frequency, rate: rate, channels: channels, frames: min(1_024, total - start), startFrame: start))
        }
    }

    static func streamFormat(rate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    /// Feeds an aggregate input like a device cycle would: microphone (mono) and tap
    /// (stereo, interleaved) at `rate`, in cycles of 512 frames.
    static func feed(_ input: AggregateCaptureInput, seconds: Double, rate: Double) {
        let cycle = 512
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        var microphone = [Float](repeating: 0, count: cycle)
        var system = [Float](repeating: 0, count: cycle * 2)
        let total = Int(seconds * rate)
        for start in stride(from: 0, to: total, by: cycle) {
            for frame in 0..<cycle {
                let time = Double(start + frame) / rate
                microphone[frame] = 0.2 * Float(sin(2 * .pi * 220 * time))
                system[2 * frame] = 0.2 * Float(sin(2 * .pi * 330 * time))
                system[2 * frame + 1] = system[2 * frame]
            }
            microphone.withUnsafeMutableBytes { microphoneBytes in
                system.withUnsafeMutableBytes { systemBytes in
                    list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(microphoneBytes.count), mData: microphoneBytes.baseAddress)
                    list[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(systemBytes.count), mData: systemBytes.baseAddress)
                    input.process(list.unsafePointer)
                }
            }
        }
    }

    /// Zero crossings per second, a robust estimate of a pure tone's frequency (2 × f).
    static func zeroCrossingRate(_ samples: ArraySlice<Float>, rate: Double) -> Double {
        var crossings = 0
        var previous = samples.first ?? 0
        for sample in samples.dropFirst() {
            if (previous < 0) != (sample < 0) { crossings += 1 }
            previous = sample
        }
        return Double(crossings) / (Double(samples.count) / rate)
    }
}

// MARK: - Pipeline

@Suite("Capture pipeline")
struct CapturePipelineTests {
    /// Streams for a capture that is driven manually (no timer).
    private func makeStreams() -> (
        chunks: AsyncStream<AudioChunk>, chunkContinuation: AsyncStream<AudioChunk>.Continuation,
        levels: AsyncStream<AudioLevel>, levelContinuation: AsyncStream<AudioLevel>.Continuation,
        events: AsyncStream<CaptureEvent>, eventContinuation: AsyncStream<CaptureEvent>.Continuation
    ) {
        let (chunks, chunkContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let (levels, levelContinuation) = AsyncStream.makeStream(of: AudioLevel.self)
        let (events, eventContinuation) = AsyncStream.makeStream(of: CaptureEvent.self)
        return (chunks, chunkContinuation, levels, levelContinuation, events, eventContinuation)
    }

    @Test("Synthesized microphone audio → CAF file: duration, pause and marker position match")
    func endToEndFile() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forWriting: url, settings: AudioFormat.recordingFileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let streams = makeStreams()
        let capture = AudioCaptureContext(tickInterval: .never)
        capture.begin(sink: file, chunks: streams.chunkContinuation, levels: streams.levelContinuation, recordsSourceActivity: false)
        let deviceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let input = try capture.configureMicrophone(format: deviceFormat)

        // 1 s at 300 Hz, then a pause (0.5 s are dropped), then 1 s at 1 kHz.
        DeviceSignal.feed(input, frequency: 300, seconds: 1, rate: 48_000, channels: 2)
        capture.processPendingAudio()
        capture.setPaused(true)
        // The marker the user sets at the pause: the recorder uses exactly this time.
        let marker = Marker(time: capture.recordedTime)
        DeviceSignal.feed(input, frequency: 700, seconds: 0.5, rate: 48_000, channels: 2)
        capture.setPaused(false)
        DeviceSignal.feed(input, frequency: 1_000, seconds: 1, rate: 48_000, channels: 2)
        let result = await capture.finish()

        #expect(abs(result.duration - 2) < 0.02)
        #expect(abs(marker.time - 1) < 0.02)

        let readBack = try AVAudioFile(forReading: url)
        #expect(readBack.fileFormat.sampleRate == AudioFormat.sampleRate)
        let fileDuration = Double(readBack.length) / readBack.processingFormat.sampleRate
        #expect(abs(fileDuration - result.duration) < 0.1)

        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: readBack.processingFormat, frameCapacity: AVAudioFrameCount(readBack.length)))
        try readBack.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let rate = readBack.processingFormat.sampleRate
        let markerFrame = Int(marker.time * rate)
        // Before the marker the first tone, after it the second; the paused tone never appears.
        let before = DeviceSignal.zeroCrossingRate(samples[Int(0.2 * rate)..<(markerFrame - Int(0.2 * rate))], rate: rate)
        let after = DeviceSignal.zeroCrossingRate(samples[(markerFrame + Int(0.2 * rate))..<min(samples.count, markerFrame + Int(0.8 * rate))], rate: rate)
        #expect(abs(before - 600) < 60, "expected 300 Hz before the marker, measured \(before / 2) Hz")
        #expect(abs(after - 2_000) < 150, "expected 1 kHz after the marker, measured \(after / 2) Hz")
    }

    @Test("Chunks cover the timeline without gaps and match the written audio")
    func contiguousChunks() async throws {
        let streams = makeStreams()
        let sink = MemorySink()
        let capture = AudioCaptureContext(tickInterval: .never)
        capture.begin(sink: sink, chunks: streams.chunkContinuation, levels: streams.levelContinuation, recordsSourceActivity: false)
        let input = try capture.configureMicrophone(format: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!)
        DeviceSignal.feed(input, frequency: 440, seconds: 1.5, rate: 44_100, channels: 1)
        capture.processPendingAudio()
        DeviceSignal.feed(input, frequency: 440, seconds: 1, rate: 44_100, channels: 1)
        let result = await capture.finish()

        var expectedStart: Int64 = 0
        for await chunk in streams.chunks {
            #expect(chunk.startFrame == expectedStart)
            expectedStart = chunk.endFrame
        }
        #expect(Int(expectedStart) == sink.frames)
        #expect(abs(result.duration - 2.5) < 0.02)
    }

    @Test("A write error stops the timeline and is reported once")
    func writeFailure() async throws {
        let streams = makeStreams()
        let sink = MemorySink(failAfterWrites: 5)
        let capture = AudioCaptureContext(tickInterval: .never)
        capture.begin(sink: sink, chunks: nil, levels: streams.levelContinuation, events: streams.eventContinuation, recordsSourceActivity: false)
        let input = try capture.configureMicrophone(format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)
        DeviceSignal.feed(input, frequency: 440, seconds: 2, rate: 48_000, channels: 1)
        capture.processPendingAudio()
        DeviceSignal.feed(input, frequency: 440, seconds: 1, rate: 48_000, channels: 1)
        let result = await capture.finish()

        // Five blocks of 100 ms were written; nothing after the failure counts as recorded.
        #expect(abs(result.duration - 0.5) < 0.001)
        #expect(sink.frames == 5 * AudioCaptureContext.blockSize)
        var events: [CaptureEvent] = []
        for await event in streams.events { events.append(event) }
        #expect(events.count == 1)
        if case .writeFailed = events.first {} else { Issue.record("Expected a write failure, got \(events)") }
    }

    @Test("Device changes mid-recording keep one continuous, aligned timeline")
    func deviceChanges() async throws {
        let streams = makeStreams()
        let sink = MemorySink()
        let capture = AudioCaptureContext(tickInterval: .never)
        capture.begin(sink: sink, chunks: streams.chunkContinuation, levels: streams.levelContinuation, recordsSourceActivity: true)

        // Built-in microphone at 48 kHz, then AirPods (headset profile, 24 kHz), then a USB
        // microphone at 44.1 kHz. The aggregate is rebuilt each time.
        for rate in [48_000.0, 24_000, 44_100] {
            let input = try capture.configure(AggregateInputLayout(
                microphone: .init(bufferIndex: 0, streamFormat: DeviceSignal.streamFormat(rate: rate, channels: 1)),
                system: .init(bufferIndex: 1, streamFormat: DeviceSignal.streamFormat(rate: rate, channels: 2))
            ))
            DeviceSignal.feed(input, seconds: 1, rate: rate)
            capture.processPendingAudio()
        }
        // The system audio only (headphones unplugged, microphone off).
        let systemOnly = try capture.configure(AggregateInputLayout(microphone: nil, system: .init(bufferIndex: 1, streamFormat: DeviceSignal.streamFormat(rate: 48_000, channels: 2))))
        DeviceSignal.feed(systemOnly, seconds: 1, rate: 48_000)
        let result = await capture.finish()

        #expect(abs(result.duration - 4) < 0.05)
        var expectedStart: Int64 = 0
        for await chunk in streams.chunks {
            #expect(chunk.startFrame == expectedStart)
            expectedStart = chunk.endFrame
        }
        #expect(Int(expectedStart) == sink.frames)
        // Source activity covers the three seconds with both sources, one bin per 100 ms.
        let activity = try #require(result.sourceActivity)
        #expect(abs(activity.binCount - 30) <= 1)
    }

    @Test("A new microphone format continues the timeline (engine path)")
    func microphoneFormatChange() async throws {
        let streams = makeStreams()
        let capture = AudioCaptureContext(tickInterval: .never)
        capture.begin(sink: MemorySink(), chunks: nil, levels: streams.levelContinuation, recordsSourceActivity: false)
        let first = try capture.configureMicrophone(format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!)
        DeviceSignal.feed(first, frequency: 440, seconds: 1, rate: 48_000, channels: 2)
        let second = try capture.configureMicrophone(format: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!)
        DeviceSignal.feed(second, frequency: 440, seconds: 1, rate: 16_000, channels: 1)
        let result = await capture.finish()
        #expect(abs(result.duration - 2) < 0.02)
    }

    @Test("A stalled consumer drops what exceeds the ring and keeps the rest")
    func stalledConsumer() async throws {
        let streams = makeStreams()
        let capture = AudioCaptureContext(tickInterval: .never)
        capture.begin(sink: MemorySink(), chunks: nil, levels: streams.levelContinuation, recordsSourceActivity: false)
        let input = try capture.configureMicrophone(format: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!)
        // Nothing is processed while 20 s arrive; the ring holds 15 s.
        DeviceSignal.feed(input, frequency: 440, seconds: 20, rate: 16_000, channels: 1)
        let result = await capture.finish()
        #expect(abs(result.duration - CaptureSource.bufferedSeconds) < 0.1)
    }

    @Test("Without a visible meter levels arrive once per second instead of ten times")
    func reducedLevels() async throws {
        let streams = makeStreams()
        let capture = AudioCaptureContext(tickInterval: .never)
        capture.begin(sink: MemorySink(), chunks: nil, levels: streams.levelContinuation, recordsSourceActivity: false)
        let input = try capture.configureMicrophone(format: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!)
        DeviceSignal.feed(input, frequency: 440, seconds: 1, rate: 16_000, channels: 1)
        capture.processPendingAudio()
        capture.setReducedLevelUpdates(true)
        DeviceSignal.feed(input, frequency: 440, seconds: 3, rate: 16_000, channels: 1)
        capture.processPendingAudio()
        await capture.finish()

        var levels: [AudioLevel] = []
        for await level in streams.levels { levels.append(level) }
        #expect(levels.count == 10 + 3)
        #expect(abs((levels.last?.recordedTime ?? 0) - 4) < 0.01)
    }

    @Test("A stalled disk blocks only the processing queue, never the control calls")
    func stalledDiskDoesNotBlockControlCalls() async throws {
        let streams = makeStreams()
        let sink = StallingSink()
        let capture = AudioCaptureContext(tickInterval: .never)
        capture.begin(sink: sink, chunks: streams.chunkContinuation, levels: streams.levelContinuation, recordsSourceActivity: false)
        let input = try capture.configureMicrophone(format: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!)
        DeviceSignal.feed(input, frequency: 440, seconds: 1, rate: 16_000, channels: 1)

        // The processing queue's part: it hangs in the first write.
        let processing = Thread { capture.processPendingAudio() }
        processing.start()
        let deadline = ContinuousClock.now + .seconds(2)
        while !sink.isWriting, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(sink.isWriting)

        // What the main actor does meanwhile: all of it returns while the disk hangs.
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            DeviceSignal.feed(input, frequency: 440, seconds: 0.5, rate: 16_000, channels: 1)
            capture.setPaused(true)
            capture.setReducedLevelUpdates(true)
            _ = capture.isPaused
            _ = capture.recordedTime
            capture.setPaused(false)
            _ = try capture.configureMicrophone(format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)
        }
        #expect(elapsed < .milliseconds(200), "control calls waited \(elapsed) for the disk")
        #expect(sink.isWriting, "the write must still hang, otherwise the test proves nothing")
        // The timeline already contains everything captured before the pause.
        #expect(abs(capture.recordedTime - 1.5) < 0.01)

        sink.release()
        let result = await capture.finish()
        #expect(abs(result.duration - 1.5) < 0.01)
        #expect(sink.writtenFrames == 24_000)
        var expectedStart: Int64 = 0
        for await chunk in streams.chunks {
            #expect(chunk.startFrame == expectedStart)
            expectedStart = chunk.endFrame
        }
        #expect(expectedStart == 24_000)
    }

    @Test("A failed device is reported as an event, only while recording")
    func inputFailureEvent() async throws {
        let streams = makeStreams()
        let capture = AudioCaptureContext(tickInterval: .never)
        capture.begin(sink: MemorySink(), chunks: nil, levels: streams.levelContinuation, events: streams.eventContinuation, recordsSourceActivity: false)
        capture.reportInputFailure("Kein Mikrofon")
        await capture.finish()
        capture.reportInputFailure("Nach dem Ende")

        var events: [CaptureEvent] = []
        for await event in streams.events { events.append(event) }
        #expect(events == [.inputFailed("Kein Mikrofon")])
    }

    @Test("Finishing twice returns the same duration and writes nothing more")
    func finishTwice() async throws {
        let streams = makeStreams()
        let sink = MemorySink()
        let capture = AudioCaptureContext(tickInterval: .never)
        capture.begin(sink: sink, chunks: nil, levels: streams.levelContinuation, recordsSourceActivity: false)
        let input = try capture.configureMicrophone(format: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!)
        DeviceSignal.feed(input, frequency: 440, seconds: 1, rate: 16_000, channels: 1)
        let first = await capture.finish()
        DeviceSignal.feed(input, frequency: 440, seconds: 1, rate: 16_000, channels: 1)
        let second = await capture.finish()
        #expect(abs(first.duration - 1) < 0.01)
        #expect(second.duration == first.duration)
        #expect(sink.frames == 16_000)
    }

    @Test("Streaming to live transcription can stop while the file is still written")
    func stopStreaming() async throws {
        let streams = makeStreams()
        let sink = MemorySink()
        let capture = AudioCaptureContext(tickInterval: .never)
        capture.begin(sink: sink, chunks: streams.chunkContinuation, levels: streams.levelContinuation, recordsSourceActivity: false)
        let input = try capture.configureMicrophone(format: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!)
        DeviceSignal.feed(input, frequency: 440, seconds: 1, rate: 16_000, channels: 1)
        capture.processPendingAudio()
        capture.stopStreamingChunks()
        DeviceSignal.feed(input, frequency: 440, seconds: 1, rate: 16_000, channels: 1)
        await capture.finish()

        var streamed = 0
        for await chunk in streams.chunks { streamed += chunk.samples.count }
        #expect(streamed == 16_000)
        #expect(sink.frames == 32_000)
    }
}
