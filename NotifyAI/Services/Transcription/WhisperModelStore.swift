//
//  WhisperModelStore.swift
//  NotifyAI
//

import Foundation

/// Locates downloaded Whisper models on disk.
///
/// WhisperKit downloads into a Hugging Face style folder hierarchy below `downloadBase`.
/// Instead of hard-coding that layout, the store searches for the variant folder. A
/// marker file is written once a model was downloaded *and* loaded successfully, so
/// interrupted downloads are never mistaken for usable models.
struct WhisperModelStore: Sendable {
    private static let readyMarkerName = ".notifyai-ready"

    let downloadBase: URL

    func folder(for model: WhisperModel) -> URL? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: downloadBase,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        for case let url as URL in enumerator where url.lastPathComponent == model.id {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                return url
            }
        }
        return nil
    }

    func isInstalled(_ model: WhisperModel) -> Bool {
        guard let folder = folder(for: model) else { return false }
        return FileManager.default.fileExists(atPath: folder.appending(path: Self.readyMarkerName).path(percentEncoded: false))
    }

    func markReady(_ model: WhisperModel, folder: URL) throws {
        try Data().write(to: folder.appending(path: Self.readyMarkerName))
    }

    func sizeOnDisk(of model: WhisperModel) -> Int64 {
        guard let folder = folder(for: model) else { return 0 }
        return StorageLocations.allocatedSize(of: folder)
    }

    func delete(_ model: WhisperModel) throws {
        guard let folder = folder(for: model) else { return }
        try FileManager.default.removeItem(at: folder)
    }
}
