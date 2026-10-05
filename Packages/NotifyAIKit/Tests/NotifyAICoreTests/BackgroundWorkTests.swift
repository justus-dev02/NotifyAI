//
//  BackgroundWorkTests.swift
//  NotifyAICoreTests
//

import NotifyAICore
import Testing

@Suite("Background work")
struct BackgroundWorkTests {
    @Test("Returns the work's result")
    func result() async {
        let value = await BackgroundWork.run(priority: .utility) { 6 * 7 }
        #expect(value == 42)
    }

    @Test("Rethrows the work's error")
    func error() async {
        struct Failure: Error {}
        await #expect(throws: Failure.self) {
            try await BackgroundWork.run(priority: .utility) { () throws -> Int in throw Failure() }
        }
    }

    @Test("Cancelling the caller cancels the work, unlike a detached task")
    func cancellationReachesTheWork() async {
        let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let caller = Task {
            await BackgroundWork.run(priority: .utility) { () -> Bool in
                startedContinuation.yield()
                // Waits until it learns about the cancellation.
                while !Task.isCancelled {
                    await Task.yield()
                }
                return Task.isCancelled
            }
        }
        for await _ in started { break }
        caller.cancel()
        #expect(await caller.value)
    }
}
