//
//  WhisperModelManager.swift
//  NotifyAI
//

import Foundation
import Observation
import OSLog
@preconcurrency import WhisperKit

/// Download state of a Whisper model, as shown in the settings.
enum WhisperModelState: Equatable, Sendable {
    case notInstalled
    case downloading(progress: Double)
    /// Downloaded; the model is being compiled for this device and the tokenizer fetched.
    case preparing
    case installed(bytes: Int64)
    case failed(message: String)
}

enum WhisperModelError: LocalizedError {
    case inUse

    var errorDescription: String? {
        switch self {
        case .inUse:
            String(localized: "Whisper wird gerade für eine Aufnahme oder Transkription verwendet. Lösche das Modell, sobald sie abgeschlossen ist.")
        }
    }
}

/// Downloads, prepares and deletes Whisper models. This is the only place in the app
/// that uses the network, and only when the user explicitly starts a download.
@MainActor
@Observable
final class WhisperModelManager {
    private(set) var states: [String: WhisperModelState] = [:]
    /// Everything below the models folder: models, tokenizers, caches and partial downloads.
    private(set) var downloadedBytes: Int64 = 0

    @ObservationIgnored let store: WhisperModelStore
    @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let onModelRemoved: @MainActor () async -> Void
    @ObservationIgnored private let isModelInUse: @MainActor () async -> Bool
    @ObservationIgnored private let logger = Logger.transcription

    init(
        store: WhisperModelStore,
        isModelInUse: @escaping @MainActor () async -> Bool = { false },
        onModelRemoved: @escaping @MainActor () async -> Void
    ) {
        self.store = store
        self.isModelInUse = isModelInUse
        self.onModelRemoved = onModelRemoved
    }

    func state(for model: WhisperModel) -> WhisperModelState {
        states[model.id] ?? .notInstalled
    }

    func isInstalled(_ model: WhisperModel) -> Bool {
        if case .installed = state(for: model) { return true }
        return false
    }

    /// Re-reads the installation state from disk. The directory scan runs off the main actor.
    func refresh() async {
        let store = store
        let (installed, total) = await Task.detached(priority: .utility) {
            let installed = WhisperModel.all.reduce(into: [String: Int64]()) { result, model in
                if store.isInstalled(model) {
                    result[model.id] = store.sizeOnDisk(of: model)
                }
            }
            return (installed, StorageLocations.allocatedSize(of: store.downloadBase))
        }.value

        for model in WhisperModel.all where downloads[model.id] == nil {
            states[model.id] = installed[model.id].map { .installed(bytes: $0) } ?? .notInstalled
        }
        downloadedBytes = total
    }

    func download(_ model: WhisperModel) {
        guard downloads[model.id] == nil else { return }
        states[model.id] = .downloading(progress: 0)

        let store = store
        let progressHandler = Self.makeProgressHandler { [weak self] fraction in
            self?.updateDownloadProgress(fraction, for: model)
        }

        downloads[model.id] = Task { [weak self] in
            do {
                let folder = try await WhisperKit.download(
                    variant: model.id,
                    downloadBase: store.downloadBase,
                    progressCallback: progressHandler
                )
                try Task.checkCancellation()
                self?.states[model.id] = .preparing

                // Loading once compiles the Core ML models for this device and caches the
                // tokenizer, so later transcriptions work without a network connection.
                let pipeline = try await WhisperKit(WhisperKitConfig(
                    downloadBase: store.downloadBase,
                    modelFolder: folder.path(percentEncoded: false),
                    tokenizerFolder: store.downloadBase,
                    verbose: false,
                    logLevel: .error,
                    load: true,
                    download: false
                ))
                await pipeline.unloadModels()
                try store.markReady(model, folder: folder)
                self?.finishDownload(of: model, result: .installed(bytes: store.sizeOnDisk(of: model)))
                await self?.refresh()
            } catch is CancellationError {
                do {
                    try store.delete(model)
                } catch {
                    Logger.transcription.error("Removing the cancelled download failed: \(error.localizedDescription, privacy: .public)")
                }
                self?.finishDownload(of: model, result: .notInstalled)
            } catch {
                Logger.transcription.error("Downloading \(model.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                self?.finishDownload(
                    of: model,
                    result: .failed(message: String(localized: "Download fehlgeschlagen. Bitte prüfe die Internetverbindung und versuche es erneut."))
                )
            }
        }
    }

    func cancelDownload(of model: WhisperModel) {
        downloads[model.id]?.cancel()
    }

    /// Deletes one model. A model that is in use is kept.
    func delete(_ model: WhisperModel) async throws {
        guard !(await isModelInUse()) else { throw WhisperModelError.inUse }
        cancelDownload(of: model)
        await onModelRemoved()
        do {
            try store.delete(model)
        } catch {
            logger.error("Deleting \(model.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        states[model.id] = .notInstalled
        await refresh()
    }

    /// Deletes every downloaded model together with what the downloads left behind:
    /// tokenizers, the download cache and interrupted downloads.
    func deleteAll() async throws {
        guard !(await isModelInUse()) else { throw WhisperModelError.inUse }
        for model in WhisperModel.all {
            cancelDownload(of: model)
        }
        await onModelRemoved()
        let directory = store.downloadBase
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let contents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for item in contents {
                try fileManager.removeItem(at: item)
            }
        }.value
        logger.info("Deleted all downloaded Whisper models")
        await refresh()
    }

    var totalInstalledBytes: Int64 {
        states.values.reduce(0) { total, state in
            if case .installed(let bytes) = state { return total + bytes }
            return total
        }
    }

    // MARK: - Private

    private func updateDownloadProgress(_ fraction: Double, for model: WhisperModel) {
        guard case .downloading(let current) = states[model.id] else { return }
        // Hub reports progress very often; one-percent steps are plenty for the UI.
        if fraction - current >= 0.01 || fraction >= 1 {
            states[model.id] = .downloading(progress: fraction)
        }
    }

    private func finishDownload(of model: WhisperModel, result: WhisperModelState) {
        downloads[model.id] = nil
        states[model.id] = result
    }

    /// The download reports progress on a background queue. Building the closure in a
    /// nonisolated context keeps it from inheriting main-actor isolation.
    private nonisolated static func makeProgressHandler(
        _ update: @escaping @MainActor (Double) -> Void
    ) -> @Sendable (Progress) -> Void {
        { progress in
            let fraction = progress.fractionCompleted
            Task { @MainActor in update(fraction) }
        }
    }
}
