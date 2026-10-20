//
//  LoadedModel.swift
//  NotifyAINeuralModels
//

import Foundation
import NotifyAICore
import NotifyAISupport
import OSLog

/// A model that is loaded from disk when it is first used and released when nobody needs it.
///
/// Users bracket their work with `use(_:)`. When the last use ends, the model is released after
/// `idleDelay`; memory pressure releases it at once. A model in use is never released.
package actor LoadedModel<Value: Sendable> {
    static var defaultIdleDelay: Duration { .seconds(120) }

    private let name: String
    private let load: @Sendable () async throws -> Value
    private let release: @Sendable (Value) async -> Void
    private let idleDelay: Duration
    private var value: Value?
    private var activeUses = 0
    private var idleUnload: Task<Void, Never>?
    private var memoryPressure: (any DispatchSourceMemoryPressure)?

    package init(
        name: String,
        idleDelay: Duration = LoadedModel.defaultIdleDelay,
        load: @escaping @Sendable () async throws -> Value,
        release: @escaping @Sendable (Value) async -> Void = { _ in }
    ) {
        self.name = name
        self.idleDelay = idleDelay
        self.load = load
        self.release = release
    }

    package var isInUse: Bool { activeUses > 0 }
    var isLoaded: Bool { value != nil }

    /// Runs `body` with the loaded model, loading it first if needed.
    package func use<Result: Sendable>(_ body: @Sendable (Value) async throws -> Result) async throws -> Result {
        activeUses += 1
        idleUnload?.cancel()
        idleUnload = nil
        defer {
            activeUses -= 1
            scheduleIdleUnload()
        }
        let loaded: Value
        if let value {
            loaded = value
        } else {
            loaded = try await load()
            value = loaded
            observeMemoryPressure()
            Logger.transcription.info("Loaded the \(self.name, privacy: .public) model")
        }
        return try await body(loaded)
    }

    /// Releases the model unless it is in use.
    func unloadIfIdle(reason: String) async {
        guard activeUses == 0, value != nil else { return }
        Logger.transcription.info("Unloading the \(self.name, privacy: .public) model (\(reason, privacy: .public))")
        await unload()
    }

    package func unload() async {
        idleUnload?.cancel()
        idleUnload = nil
        memoryPressure?.cancel()
        memoryPressure = nil
        if let value {
            self.value = nil
            await release(value)
        }
    }

    private func scheduleIdleUnload() {
        guard activeUses == 0, value != nil else { return }
        idleUnload?.cancel()
        let delay = idleDelay
        idleUnload = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle(reason: "idle")
        }
    }

    private func observeMemoryPressure() {
        guard memoryPressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            Task { await self?.unloadIfIdle(reason: "memory pressure") }
        }
        source.resume()
        memoryPressure = source
    }
}
