//
//  NeuralModelManager.swift
//  NotifyAINeuralModels
//

import FluidAudio
import Foundation
import NotifyAICore
import NotifyAIPersistence
import NotifyAISupport
import Observation
import OSLog

/// Who uses a loaded neural model. A model in use must not be deleted; a deleted model must
/// be released. Implemented by `NeuralSpeakerDiarizer` and `ParakeetEngine`; the manager
/// knows them only through this protocol, so it does not depend on transcription or speaker
/// detection.
package protocol NeuralModelUsage: Sendable {
    var model: NeuralSpeechModel { get }
    /// Whether a recording or processing job is using the model right now.
    var isInUse: Bool { get async }
    /// Releases the loaded model.
    func unloadModel() async
    /// Loads the downloaded files the way recognition loads them, which also compiles them for
    /// this device. Throws if they cannot be used.
    func verifyDownload() throws
}

/// Downloads, prepares and deletes the speaker recognition and Parakeet models. Uses the
/// network only when the user explicitly starts a download; recognition itself runs offline.
@MainActor
@Observable
public final class NeuralModelManager {
    private(set) var states: [NeuralSpeechModel: ModelInstallState] = [:]
    /// Everything below the models folder, including partial downloads.
    public private(set) var downloadedBytes: Int64 = 0

    @ObservationIgnored let store: NeuralModelStore
    @ObservationIgnored private var downloads: [NeuralSpeechModel: Task<Void, Never>] = [:]
    @ObservationIgnored private let usages: [NeuralSpeechModel: any NeuralModelUsage]
    @ObservationIgnored private let logger = Logger.transcription

    package init(store: NeuralModelStore, usages: [any NeuralModelUsage]) {
        self.store = store
        self.usages = Dictionary(usages.map { ($0.model, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func state(for model: NeuralSpeechModel) -> ModelInstallState {
        states[model] ?? .notInstalled
    }

    public func isInstalled(_ model: NeuralSpeechModel) -> Bool {
        state(for: model).isInstalled
    }

    /// Re-reads the installation state from disk, off the main actor.
    public func refresh() async {
        let store = store
        let (installed, total) = await BackgroundWork.run(priority: .utility) {
            let installed = NeuralSpeechModel.allCases.reduce(into: [NeuralSpeechModel: Int64]()) { result, model in
                if store.isInstalled(model) {
                    result[model] = store.sizeOnDisk(of: model)
                }
            }
            return (installed, StorageLocations.allocatedSize(of: store.downloadBase))
        }
        for model in NeuralSpeechModel.allCases where downloads[model] == nil {
            states[model] = installed[model].map { .installed(bytes: $0) } ?? .notInstalled
        }
        downloadedBytes = total
    }

    public func download(_ model: NeuralSpeechModel) {
        guard downloads[model] == nil else { return }
        states[model] = .downloading(progress: 0)
        let store = store
        let usage = usages[model]
        let progress = Self.makeProgressHandler { [weak self] fraction, isCompiling in
            self?.updateProgress(fraction, isCompiling: isCompiling, for: model)
        }
        downloads[model] = Task { [weak self] in
            do {
                try await Self.fetch(model, into: store, verifiedBy: usage, progress: progress)
                try Task.checkCancellation()
                try store.markReady(model)
                self?.finishDownload(of: model, result: .installed(bytes: store.sizeOnDisk(of: model)))
                await self?.refresh()
            } catch is CancellationError {
                Self.removeDownload(of: model, from: store)
                self?.finishDownload(of: model, result: .notInstalled)
            } catch {
                Logger.transcription.error("Downloading \(model.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                if Task.isCancelled {
                    Self.removeDownload(of: model, from: store)
                    self?.finishDownload(of: model, result: .notInstalled)
                } else {
                    self?.finishDownload(
                        of: model,
                        result: .failed(message: String(localized: "Download fehlgeschlagen. Bitte prüfe die Internetverbindung und versuche es erneut.", bundle: .module))
                    )
                }
            }
        }
    }

    public func cancelDownload(of model: NeuralSpeechModel) {
        downloads[model]?.cancel()
    }

    /// Deletes one model. A model that is in use is kept.
    public func delete(_ model: NeuralSpeechModel) async throws {
        if let usage = usages[model] {
            guard !(await usage.isInUse) else { throw NeuralModelError.inUse }
            await usage.unloadModel()
        }
        cancelDownload(of: model)
        do {
            try store.delete(model)
        } catch {
            logger.error("Deleting \(model.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        states[model] = .notInstalled
        await refresh()
    }

    /// Deletes every downloaded neural model.
    public func deleteAll() async throws {
        for model in NeuralSpeechModel.allCases {
            if let usage = usages[model], await usage.isInUse { throw NeuralModelError.inUse }
        }
        for model in NeuralSpeechModel.allCases {
            cancelDownload(of: model)
            await usages[model]?.unloadModel()
            try store.delete(model)
        }
        logger.info("Deleted all neural models")
        await refresh()
    }

    // MARK: - Private

    /// Downloads the model and loads it once, which compiles it for this device.
    @concurrent
    private static func fetch(
        _ model: NeuralSpeechModel,
        into store: NeuralModelStore,
        verifiedBy usage: (any NeuralModelUsage)?,
        progress: @escaping ProgressHandler
    ) async throws {
        switch model {
        case .speakers:
            _ = try await OfflineDiarizerModels.load(from: store.downloadBase, progressHandler: progress)
        case .parakeet:
            let folder = store.downloadFolder(for: model)
            try await AsrModels.download(to: folder, version: NeuralSpeechModel.parakeetVersion, progressHandler: progress)
        }
        try usage?.verifyDownload()
    }

    nonisolated private static func removeDownload(of model: NeuralSpeechModel, from store: NeuralModelStore) {
        do {
            try store.delete(model)
        } catch {
            Logger.transcription.error("Removing the cancelled download failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Files are downloaded and compiled one after another; the bar only moves forward, and
    /// compiling shows as "preparing".
    private func updateProgress(_ fraction: Double, isCompiling: Bool, for model: NeuralSpeechModel) {
        guard downloads[model] != nil else { return }
        if isCompiling {
            states[model] = .preparing
            return
        }
        switch states[model] {
        case .downloading(let current):
            // Progress arrives very often; one-percent steps are plenty for the UI.
            if fraction - current >= 0.01 || (fraction >= 1 && current < 1) {
                states[model] = .downloading(progress: fraction)
            }
        case .preparing:
            states[model] = .downloading(progress: fraction)
        default:
            break
        }
    }

    private func finishDownload(of model: NeuralSpeechModel, result: ModelInstallState) {
        downloads[model] = nil
        states[model] = result
    }

    /// The download reports progress on its own queue. Building the closure in a
    /// nonisolated context keeps it from inheriting main-actor isolation.
    nonisolated private static func makeProgressHandler(
        _ update: @escaping @MainActor (Double, Bool) -> Void
    ) -> ProgressHandler {
        { progress in
            let fraction = progress.fractionCompleted
            let isCompiling = if case .compiling = progress.phase { true } else { false }
            Task { @MainActor in update(fraction, isCompiling) }
        }
    }
}
