//
//  EchoCancellationPipelineTests.swift
//  NotifyAITests
//
//  Echo cancellation inside the capture path: a "Mikrofon + Systemton" recording without
//  headphones, through device changes, with an exact timeline.
//

@testable import AudioCapture
import AVFoundation
import Foundation
@testable import NotifyAICore
import Testing

/// Device input of a meeting without headphones.
enum EchoSignal {
    /// Feeds an aggregate input whose microphone hears only the speakers: the system audio
    /// (broadband noise) 40 ms later and at a third of its level, as without headphones.
    /// `startFrame` continues the signal across device changes.
    /// - Returns: The number of frames fed (whole device cycles).
    @discardableResult
    static func feed(_ input: AggregateCaptureInput, seconds: Double, rate: Double, startFrame: Int = 0) -> Int {
        let cycle = 512
        let delay = Int(0.04 * rate)
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        var microphone = [Float](repeating: 0, count: cycle)
        var system = [Float](repeating: 0, count: cycle * 2)
        let total = Int(seconds * rate)
        for start in stride(from: 0, to: total, by: cycle) {
            for frame in 0..<cycle {
                let index = startFrame + start + frame
                microphone[frame] = index >= delay ? 0.33 * noise(index - delay) : 0
                system[2 * frame] = noise(index)
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
        return (total + cycle - 1) / cycle * cycle
    }

    /// Deterministic noise in -0.2…0.2 for a frame index.
    private static func noise(_ index: Int) -> Float {
        let value = sin(Double(index) * 12.989_8) * 43_758.545_3
        return Float(0.4 * (value - value.rounded(.down)) - 0.2)
    }

}

@Suite("Capture pipeline: echo cancellation")
struct EchoCancellationPipelineTests {
    @Test("Echo cancellation removes the speakers from the microphone and keeps the timeline complete", arguments: [true, false])
    func echoCancellation(cancelsEcho: Bool) async throws {
        let (chunks, chunkContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let (_, levelContinuation) = AsyncStream.makeStream(of: AudioLevel.self)
        let sink = MemorySink()
        let capture = AudioCaptureContext(tickInterval: .never)
        capture.begin(sink: sink, chunks: chunkContinuation, levels: levelContinuation, recordsSourceActivity: true, cancelsEcho: cancelsEcho)

        // Five seconds at 48 kHz, then a device change (the echo path is learned again).
        var expectedDuration: TimeInterval = 0
        for (rate, seconds) in [(48_000.0, 5.0), (44_100.0, 4.0)] {
            let input = try capture.configure(AggregateInputLayout(
                microphone: .init(bufferIndex: 0, streamFormat: DeviceSignal.streamFormat(rate: rate, channels: 1)),
                system: .init(bufferIndex: 1, streamFormat: DeviceSignal.streamFormat(rate: rate, channels: 2))
            ))
            // The signal continues where the previous second ended.
            var position = 0
            for _ in 0..<Int(seconds) {
                let frames = EchoSignal.feed(input, seconds: 1, rate: rate, startFrame: position)
                position += frames
                expectedDuration += Double(frames) / rate
                capture.processPendingAudio()
            }
        }
        let result = await capture.finish()

        // Nothing is lost or added: all fed audio, one continuous run of chunks.
        #expect(abs(result.duration - expectedDuration) < 0.005)
        var expectedStart: Int64 = 0
        for await chunk in chunks {
            #expect(chunk.startFrame == expectedStart)
            expectedStart = chunk.endFrame
        }
        #expect(Int(expectedStart) == sink.frames)

        // The microphone's level in the last two seconds of each device: the echo is gone.
        let activity = try #require(result.sourceActivity)
        let microphone = activity.microphoneLevels
        let system = activity.systemLevels
        for range in [30..<50, 70..<90] {
            let echoLevel = range.map { microphone[$0] }.reduce(0, +) / Float(range.count)
            let referenceLevel = range.map { system[$0] }.reduce(0, +) / Float(range.count)
            if cancelsEcho {
                #expect(referenceLevel - echoLevel > 25, "Echo only \(referenceLevel - echoLevel) dB below the system audio")
            } else {
                // Without cancellation the echo is a third of the system audio (−9.5 dB).
                #expect(abs(referenceLevel - echoLevel - 9.5) < 1.5)
            }
        }
    }
}
