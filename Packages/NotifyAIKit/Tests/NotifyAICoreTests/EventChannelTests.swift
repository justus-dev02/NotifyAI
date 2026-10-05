//
//  EventChannelTests.swift
//  NotifyAICoreTests
//

import NotifyAICore
import Testing

@Suite("Event channel")
@MainActor
struct EventChannelTests {
    @Test("Every subscriber receives every event, in the order of subscription")
    func fanOut() {
        let channel = EventChannel<Int>()
        var received: [String] = []
        let first = channel.subscribe { received.append("first \($0)") }
        let second = channel.subscribe { received.append("second \($0)") }

        channel.send(1)
        channel.send(2)
        #expect(received == ["first 1", "second 1", "first 2", "second 2"])
        _ = (first, second)
    }

    @Test("A second subscriber does not replace the first one")
    func noSilentReplacement() {
        let channel = EventChannel<String>()
        var first = 0
        var second = 0
        let a = channel.subscribe { _ in first += 1 }
        let b = channel.subscribe { _ in second += 1 }
        channel.send("x")
        #expect(first == 1)
        #expect(second == 1)
        _ = (a, b)
    }

    @Test("Cancelling or releasing a subscription ends it")
    func subscriptionLifetime() {
        let channel = EventChannel<Int>()
        var received: [Int] = []
        let kept = channel.subscribe { received.append($0) }
        var released: EventSubscription? = channel.subscribe { received.append($0 * 100) }
        #expect(channel.hasSubscribers)

        channel.send(1)
        released = nil
        channel.send(2)
        kept.cancel()
        kept.cancel()
        channel.send(3)

        #expect(received == [1, 100, 2])
        #expect(!channel.hasSubscribers)
        #expect(released == nil)
    }

    @Test("Subscriptions collected with store(in:) last as long as the array")
    func storeIn() {
        let channel = EventChannel<Int>()
        var count = 0
        var subscriptions: [EventSubscription] = []
        channel.subscribe { _ in count += 1 }.store(in: &subscriptions)
        channel.send(1)
        subscriptions.removeAll()
        channel.send(2)
        #expect(count == 1)
    }
}
