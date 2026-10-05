//
//  Waiting.swift
//  NotifyAITests
//
//  Waiting for asynchronous effects without fixed delays or polling.
//

import Foundation
import NotifyAICore
import Observation

/// Waits until `condition` holds. Driven by Observation: the wait wakes up when observable
/// state that `condition` reads changes (models, services, view state), never polls and never
/// relies on a delay. A condition that never holds ends with the suite's time limit.
@MainActor
func waitUntil(_ condition: @MainActor () -> Bool) async {
    while !condition() {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = condition()
            } onChange: {
                continuation.resume()
            }
        }
    }
}

/// The next event of `channel`, e.g. a recording that stopped on its own.
@MainActor
func nextEvent<Event: Sendable>(of channel: EventChannel<Event>, after action: @MainActor () -> Void = {}) async -> Event {
    var subscription: EventSubscription?
    let event = await withCheckedContinuation { (continuation: CheckedContinuation<Event, Never>) in
        var delivered = false
        subscription = channel.subscribe { event in
            guard !delivered else { return }
            delivered = true
            continuation.resume(returning: event)
        }
        action()
    }
    subscription?.cancel()
    return event
}

/// A one-shot signal between a test and a mock that runs elsewhere (an actor, a background
/// task). `wait()` returns once `signal()` was called, also if that happened before.
final class TestGate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    func signal() {
        continuation.yield()
    }

    func wait() async {
        for await _ in stream {
            return
        }
    }
}
