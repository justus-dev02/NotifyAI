//
//  NeuralSpeechModel.swift
//  NotifyAINeuralModels
//

import FluidAudio
import Foundation
import NotifyAIPersistence
import NotifyAISupport

/// The Core ML models from FluidAudio that NotifyAI can download, besides Whisper.
public enum NeuralSpeechModel: String, CaseIterable, Identifiable, Sendable {
    /// pyannote segmentation, WeSpeaker embeddings and PLDA/VBx clustering: who spoke when,
    /// and a voice print per speaker for recognizing them in later recordings.
    case speakers
    /// NVIDIA Parakeet TDT 0.6B (post-trained "Ultra" weights), 25 European languages.
    case parakeet

    public var id: String { rawValue }

    /// Product names; they are not translated.
    public var name: String {
        switch self {
        case .speakers: "pyannote + WeSpeaker"
        case .parakeet: "Parakeet TDT 0.6B"
        }
    }

    public var detail: String {
        switch self {
        case .speakers:
            String(localized: "Erkennt, wer wann spricht, und merkt sich Stimmen, die du benennst.", bundle: .module)
        case .parakeet:
            String(localized: "Sehr schnelle Spracherkennung für 25 europäische Sprachen, auch live.", bundle: .module)
        }
    }

    public var approximateSize: String {
        switch self {
        case .speakers: String(localized: "ca. 20 MB", bundle: .module)
        case .parakeet: String(localized: "ca. 610 MB", bundle: .module)
        }
    }

    /// The repository on Hugging Face.
    var repo: Repo {
        switch self {
        case .speakers: .diarizer
        case .parakeet: .parakeetUltra
        }
    }

    /// The Parakeet weights.
    package static let parakeetVersion = AsrModelVersion.ultra

    /// A file the model's folder must contain; identifies the folder below the download base.
    var requiredFile: String {
        switch self {
        case .speakers: ModelNames.OfflineDiarizer.segmentationFile
        case .parakeet: ModelNames.ASR.preprocessorFile
        }
    }
}

/// Locates downloaded neural models on disk.
///
/// FluidAudio downloads into one folder per repository below `downloadBase`. A marker file
/// is written once a model was downloaded *and* loaded successfully, so an interrupted
/// download is never mistaken for a usable model. Models are only ever loaded from a folder
/// with the marker, never downloaded implicitly.
package struct NeuralModelStore: Sendable {
    private static let readyMarkerName = ".notifyai-ready"

    let downloadBase: URL

    package init(downloadBase: URL) {
        self.downloadBase = downloadBase
    }

    /// The repository folder FluidAudio downloads into.
    func downloadFolder(for model: NeuralSpeechModel) -> URL {
        downloadBase.appending(path: model.repo.folderName, directoryHint: .isDirectory)
    }

    /// The folder that holds the model's files, if it was downloaded.
    package func folder(for model: NeuralSpeechModel) -> URL? {
        let fileManager = FileManager.default
        let root = downloadFolder(for: model)
        if fileManager.fileExists(atPath: root.appending(path: model.requiredFile).path(percentEncoded: false)) {
            return root
        }
        // Some repositories keep the models in a subfolder per variant.
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == model.requiredFile {
            return url.deletingLastPathComponent()
        }
        return nil
    }

    package func isInstalled(_ model: NeuralSpeechModel) -> Bool {
        FileManager.default.fileExists(atPath: readyMarker(for: model).path(percentEncoded: false))
    }

    func markReady(_ model: NeuralSpeechModel) throws {
        try Data().write(to: readyMarker(for: model))
    }

    func sizeOnDisk(of model: NeuralSpeechModel) -> Int64 {
        StorageLocations.allocatedSize(of: downloadFolder(for: model))
    }

    func delete(_ model: NeuralSpeechModel) throws {
        let folder = downloadFolder(for: model)
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    private func readyMarker(for model: NeuralSpeechModel) -> URL {
        downloadFolder(for: model).appending(path: Self.readyMarkerName)
    }
}

package enum NeuralModelError: LocalizedError {
    case notInstalled(NeuralSpeechModel)
    case inUse

    package var errorDescription: String? {
        switch self {
        case .notInstalled(let model):
            String(localized: "Das Modell „\(model.name)“ ist noch nicht geladen. Du kannst es in den Einstellungen herunterladen.", bundle: .module)
        case .inUse:
            String(localized: "Das Modell wird gerade verwendet. Lösche es, sobald die Verarbeitung abgeschlossen ist.", bundle: .module)
        }
    }
}
