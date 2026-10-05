//
//  BackgroundWork.swift
//  NotifyAICore
//

import Foundation

/// Runs CPU-heavy work away from the calling actor at a chosen priority, as a child task.
///
/// The rule of the code base for work that must leave the main actor:
/// - Same priority as the caller: a `@concurrent` function.
/// - Lower priority (indexing, chapter digests, speaker detection): `BackgroundWork.run`.
/// - Never `Task.detached`: a detached task does not learn that its caller was cancelled,
///   so an interrupted job would keep computing a result nobody waits for.
///
/// The work runs as a child of the calling task: cancelling the caller cancels it, and the
/// caller waits for it. Long loops inside `work` should check `Task.isCancelled`.
public enum BackgroundWork {
    public static func run<Result: Sendable>(
        priority: TaskPriority,
        _ work: @escaping @Sendable () async -> Result
    ) async -> Result {
        await withTaskGroup(of: Result.self) { group in
            group.addTask(priority: priority, operation: work)
            // The group holds exactly one task, so `next()` returns its result.
            var result: Result?
            for await value in group {
                result = value
            }
            guard let result else { preconditionFailure("A task group with one task returned no result") }
            return result
        }
    }

    public static func run<Result: Sendable>(
        priority: TaskPriority,
        _ work: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await withThrowingTaskGroup(of: Result.self) { group in
            group.addTask(priority: priority, operation: work)
            var result: Result?
            for try await value in group {
                result = value
            }
            guard let result else { preconditionFailure("A task group with one task returned no result") }
            return result
        }
    }
}
