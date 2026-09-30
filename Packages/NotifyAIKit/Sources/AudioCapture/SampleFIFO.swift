//
//  SampleFIFO.swift
//  AudioCapture
//

/// A first-in, first-out queue of samples with amortized O(1) removal from the front.
///
/// `Array.removeFirst(_:)` moves every remaining element, which made the old capture path
/// O(n) per block. Here the front is an index; the storage is compacted only when the
/// consumed part is larger than the rest, so every sample is moved at most once more.
public struct SampleFIFO {
    private var storage: [Float] = []
    private var head = 0

    public init(reservingCapacity capacity: Int = 0) {
        storage.reserveCapacity(capacity)
    }

    public var count: Int { storage.count - head }
    public var isEmpty: Bool { count == 0 }

    public mutating func append(_ samples: UnsafeBufferPointer<Float>) {
        storage.append(contentsOf: samples)
    }

    public mutating func append(contentsOf samples: some Collection<Float>) {
        storage.append(contentsOf: samples)
    }

    public mutating func appendSilence(_ count: Int) {
        guard count > 0 else { return }
        storage.append(contentsOf: repeatElement(0, count: count))
    }

    /// The first `count` samples, without removing them.
    public func prefix(_ count: Int) -> ArraySlice<Float> {
        storage[head..<(head + min(count, self.count))]
    }

    public mutating func removeFirst(_ count: Int) {
        head += min(count, self.count)
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        } else if head > storage.count / 2 {
            storage.removeFirst(head)
            head = 0
        }
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }
}
