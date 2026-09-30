//
//  SampleRingBuffer.swift
//  AudioCapture
//

import Synchronization

/// A lock-free single-producer, single-consumer ring buffer of `Float` samples.
///
/// The producer is a real-time audio thread, the consumer the capture processing queue.
/// Neither side ever blocks, allocates or takes a lock: the storage is allocated once and
/// the two positions are atomics. The producer publishes samples with a releasing store of
/// `writePosition`, the consumer frees space with a releasing store of `readPosition`;
/// each side reads the other's position with an acquiring load, which makes the sample
/// memory written before the store visible after the load.
///
/// Positions count samples since the start and are never wrapped; the storage index is the
/// position modulo `capacity`. `Int` positions cannot overflow in practice (2⁶³ samples at
/// 48 kHz are six million years).
///
/// Thread safety: `write` and `recordDrop` may only be called from one producer thread at a
/// time, `read`, `availableToRead` and `takeDroppedSamples` only from one consumer thread.
public final class SampleRingBuffer: @unchecked Sendable {
    public let capacity: Int

    private let storage: UnsafeMutablePointer<Float>
    private let writePosition = Atomic<Int>(0)
    private let readPosition = Atomic<Int>(0)
    private let droppedSamples = Atomic<Int>(0)

    public init(capacity: Int) {
        precondition(capacity > 0, "A ring buffer needs room for at least one sample")
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
    }

    // MARK: Producer

    /// Free space in samples, as seen by the producer.
    public var freeSpace: Int {
        capacity - (writePosition.load(ordering: .relaxed) - readPosition.load(ordering: .acquiring))
    }

    /// Writes `count` samples produced by `fill`, or nothing if they do not fit.
    ///
    /// `fill` is called once or twice (when the region wraps around the end of the storage)
    /// with a destination region and the offset of that region within the `count` samples.
    /// - Returns: `false` if there was not enough space; the samples are then counted as dropped.
    @discardableResult
    public func write(count: Int, _ fill: (_ destination: UnsafeMutableBufferPointer<Float>, _ offset: Int) -> Void) -> Bool {
        guard count > 0 else { return true }
        guard count <= freeSpace else {
            recordDrop(count)
            return false
        }
        let position = writePosition.load(ordering: .relaxed)
        let start = position % capacity
        let firstLength = min(count, capacity - start)
        fill(UnsafeMutableBufferPointer(start: storage + start, count: firstLength), 0)
        if firstLength < count {
            fill(UnsafeMutableBufferPointer(start: storage, count: count - firstLength), firstLength)
        }
        writePosition.store(position + count, ordering: .releasing)
        return true
    }

    /// Counts samples the producer had to discard, e.g. because another ring of the same
    /// capture was full and both must stay aligned.
    public func recordDrop(_ count: Int) {
        droppedSamples.add(count, ordering: .relaxed)
    }

    // MARK: Consumer

    /// Samples ready to be read, as seen by the consumer.
    public var availableToRead: Int {
        writePosition.load(ordering: .acquiring) - readPosition.load(ordering: .relaxed)
    }

    /// Copies up to `maximumCount` samples into `destination`.
    /// - Returns: The number of samples copied.
    @discardableResult
    public func read(into destination: UnsafeMutablePointer<Float>, maximumCount: Int) -> Int {
        let count = min(maximumCount, availableToRead)
        guard count > 0 else { return 0 }
        let position = readPosition.load(ordering: .relaxed)
        let start = position % capacity
        let firstLength = min(count, capacity - start)
        destination.update(from: storage + start, count: firstLength)
        if firstLength < count {
            (destination + firstLength).update(from: storage, count: count - firstLength)
        }
        readPosition.store(position + count, ordering: .releasing)
        return count
    }

    /// Discards everything that is ready to be read.
    public func skipAvailable() {
        let count = availableToRead
        guard count > 0 else { return }
        readPosition.store(readPosition.load(ordering: .relaxed) + count, ordering: .releasing)
    }

    /// Samples dropped since the last call.
    public func takeDroppedSamples() -> Int {
        droppedSamples.exchange(0, ordering: .relaxed)
    }
}
