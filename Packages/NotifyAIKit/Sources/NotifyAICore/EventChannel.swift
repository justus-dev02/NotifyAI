//
//  EventChannel.swift
//  NotifyAICore
//

import Foundation

/// Delivers the events of one source to any number of subscribers.
///
/// This is how services tell each other what happened (a note was deleted, a job started, a
/// recording was interrupted) without knowing who listens. It replaces single callback slots
/// such as `var onNotesDeleted: (([UUID]) -> Void)?`, where a second listener silently
/// replaced the first one.
///
/// - Delivery is synchronous, on the main actor, in the order of subscription. A listener
///   therefore sees the state right after the change, and tests need no waiting.
/// - A subscription lasts as long as the returned `EventSubscription` is kept. Releasing it
///   (or calling `cancel()`) ends it, so a deallocated listener is never called.
/// - A listener that subscribes while an event is delivered receives the next event.
@MainActor
public final class EventChannel<Event> {
    private var handlers: [(id: UUID, handler: @MainActor (Event) -> Void)] = []

    public init() {}

    /// Whether anybody listens; lets a source skip building expensive events.
    public var hasSubscribers: Bool { !handlers.isEmpty }

    /// Registers a listener. Keep the returned subscription as long as events should arrive.
    public func subscribe(_ handler: @escaping @MainActor (Event) -> Void) -> EventSubscription {
        let id = UUID()
        handlers.append((id, handler))
        return EventSubscription { [weak self] in
            self?.handlers.removeAll { $0.id == id }
        }
    }

    /// Delivers the event to every current listener.
    public func send(_ event: Event) {
        for entry in handlers {
            entry.handler(event)
        }
    }
}

/// Keeps a subscription to an `EventChannel` alive; releasing it ends the subscription.
@MainActor
public final class EventSubscription {
    private var cancellation: (@MainActor () -> Void)?

    init(cancellation: @escaping @MainActor () -> Void) {
        self.cancellation = cancellation
    }

    /// Ends the subscription. Calling it again does nothing.
    public func cancel() {
        cancellation?()
        cancellation = nil
    }

    isolated deinit {
        cancel()
    }
}

extension EventSubscription {
    /// Collects subscriptions in an array that lives as long as the listener.
    public func store(in subscriptions: inout [EventSubscription]) {
        subscriptions.append(self)
    }
}
