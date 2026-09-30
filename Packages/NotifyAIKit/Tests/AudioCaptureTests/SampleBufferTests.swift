//
//  SampleBufferTests.swift
//  AudioCaptureTests
//
//  The lock-free ring between the audio threads and the processing queue, the FIFO of the
//  processing queue and the real-time downmix.
//

@testable import AudioCapture
import Foundation
import Testing

@Suite("Ring buffer and FIFO")
struct SampleBufferTests {
    @Test("Samples come out in order, also across the end of the storage")
    func wrapAround() {
        let ring = SampleRingBuffer(capacity: 8)
        var output = [Float](repeating: 0, count: 8)

        #expect(ring.write(count: 6) { destination, offset in
            for index in destination.indices { destination[index] = Float(offset + index) }
        })
        #expect(output.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maximumCount: 4) } == 4)
        #expect(Array(output.prefix(4)) == [0, 1, 2, 3])

        // 2 left, 6 free: this write wraps around the end of the storage.
        #expect(ring.write(count: 5) { destination, offset in
            for index in destination.indices { destination[index] = Float(10 + offset + index) }
        })
        #expect(ring.availableToRead == 7)
        #expect(output.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maximumCount: 8) } == 7)
        #expect(Array(output.prefix(7)) == [4, 5, 10, 11, 12, 13, 14])
    }

    @Test("A write that does not fit is dropped as a whole and counted")
    func overflow() {
        let ring = SampleRingBuffer(capacity: 4)
        #expect(ring.write(count: 3) { destination, _ in destination.initialize(repeating: 1) })
        #expect(!ring.write(count: 2) { _, _ in Issue.record("Must not be called when the samples do not fit") })
        #expect(ring.takeDroppedSamples() == 2)
        #expect(ring.takeDroppedSamples() == 0)
        #expect(ring.availableToRead == 3)
        ring.skipAvailable()
        #expect(ring.availableToRead == 0)
        #expect(ring.freeSpace == 4)
    }

    @Test("Producer and consumer on different threads exchange every sample in order")
    func concurrentProducerConsumer() async {
        let ring = SampleRingBuffer(capacity: 1_024)
        let total = 200_000
        let producer = Task.detached {
            var next = 0
            while next < total {
                let count = min(97, total - next)
                let start = next
                if ring.write(count: count, { destination, offset in
                    for index in destination.indices { destination[index] = Float(start + offset + index) }
                }) {
                    next += count
                } else {
                    // Full: the producer of a real device would drop; here we retry to check ordering.
                    _ = ring.takeDroppedSamples()
                    await Task.yield()
                }
            }
        }
        var received = 0
        var isOrdered = true
        var buffer = [Float](repeating: 0, count: 256)
        while received < total {
            let count = buffer.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maximumCount: 256) }
            for index in 0..<count where buffer[index] != Float(received + index) {
                isOrdered = false
            }
            received += count
            if count == 0 { await Task.yield() }
        }
        await producer.value
        #expect(isOrdered)
        #expect(received == total)
    }

    @Test("The FIFO removes from the front without losing or reordering samples")
    func fifo() {
        var fifo = SampleFIFO()
        fifo.append(contentsOf: (0..<10).map(Float.init))
        #expect(Array(fifo.prefix(3)) == [0, 1, 2])
        fifo.removeFirst(3)
        fifo.append(contentsOf: [10, 11])
        #expect(fifo.count == 9)
        fifo.removeFirst(6) // compacts internally
        #expect(Array(fifo.prefix(10)) == [9, 10, 11])
        fifo.appendSilence(2)
        #expect(Array(fifo.prefix(10)) == [9, 10, 11, 0, 0])
        fifo.removeFirst(99)
        #expect(fifo.isEmpty)
    }

    @Test("Downmixing averages the channels, interleaved and planar")
    func downmix() {
        let ring = SampleRingBuffer(capacity: 16)
        let interleaved: [Float] = [1, 0, 0.5, 0.5, -1, 1]
        interleaved.withUnsafeBufferPointer {
            AudioDownmix.write(interleaved: $0.baseAddress!, channelCount: 2, frames: 3, to: ring)
        }
        var output = [Float](repeating: 0, count: 3)
        _ = output.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maximumCount: 3) }
        #expect(output == [0.5, 0.5, 0])

        var left: [Float] = [1, 1]
        var right: [Float] = [0, -1]
        left.withUnsafeMutableBufferPointer { leftPointer in
            right.withUnsafeMutableBufferPointer { rightPointer in
                let channels = [leftPointer.baseAddress!, rightPointer.baseAddress!]
                channels.withUnsafeBufferPointer {
                    AudioDownmix.write(planar: $0.baseAddress!, channelCount: 2, frames: 2, to: ring)
                }
            }
        }
        _ = output.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maximumCount: 2) }
        #expect(Array(output.prefix(2)) == [0.5, 0])
    }
}
