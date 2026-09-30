//
//  StorageLocations.swift
//  NotifyAI
//

import Foundation
import NotifyAICore

/// File-system layout of the app. Everything lives inside the app's own container
/// (`Application Support/NotifyAI`) and never leaves the device.
struct StorageLocations: Sendable {
    let root: URL

    var recordingsDirectory: URL { root.appending(path: "Recordings", directoryHint: .isDirectory) }
    var whisperModelsDirectory: URL { root.appending(path: "Models/Whisper", directoryHint: .isDirectory) }
    var databaseURL: URL { root.appending(path: "NotifyAI.store", directoryHint: .notDirectory) }
    /// The search index for "Notizen fragen" and related notes, one file per note. Can be rebuilt at any time.
    var knowledgeIndexDirectory: URL { root.appending(path: "KnowledgeIndex", directoryHint: .isDirectory) }
    /// The single-file index of earlier versions; removed when the new index loads.
    var legacyKnowledgeIndexURL: URL { root.appending(path: "KnowledgeIndex.plist", directoryHint: .notDirectory) }
    /// Intermediate results of long summaries (chapter digests), removed when a summary is done.
    var processingDirectory: URL { root.appending(path: "Processing", directoryHint: .isDirectory) }
    /// MetricKit reports, kept on the device until the user exports a diagnosis.
    var diagnosticsDirectory: URL { root.appending(path: "Diagnostics", directoryHint: .isDirectory) }
    /// Databases that could not be opened are moved here instead of being deleted.
    var recoveryDirectory: URL { root.appending(path: "Recovery", directoryHint: .isDirectory) }

    /// The database and its SQLite side files.
    var databaseFiles: [URL] {
        ["", "-wal", "-shm"].map { suffix in
            root.appending(path: databaseURL.lastPathComponent + suffix, directoryHint: .notDirectory)
        }
    }

    /// Moves the database into a dated folder below `recoveryDirectory`, so a new one can
    /// be created. Nothing is deleted: the old database stays available for support.
    /// - Returns: The folder the files were moved to.
    @discardableResult
    func moveDatabaseAside(now: Date = .now) throws -> URL {
        let fileManager = FileManager.default
        let stamp = now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let destination = recoveryDirectory.appending(path: "Database-\(stamp)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for file in databaseFiles where fileManager.fileExists(atPath: file.path(percentEncoded: false)) {
            try fileManager.moveItem(at: file, to: destination.appending(path: file.lastPathComponent))
        }
        return destination
    }

    /// The production layout inside Application Support.
    static func applicationSupport() throws -> StorageLocations {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let locations = StorageLocations(root: base.appending(path: "NotifyAI", directoryHint: .isDirectory))
        try locations.createDirectories()
        return locations
    }

    /// An isolated layout in the temporary directory, used by tests and previews.
    static func temporary() throws -> StorageLocations {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "NotifyAI-\(UUID().uuidString)", directoryHint: .isDirectory)
        let locations = StorageLocations(root: root)
        try locations.createDirectories()
        return locations
    }

    func createDirectories() throws {
        let fileManager = FileManager.default
        for directory in [root, recordingsDirectory, whisperModelsDirectory, processingDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        #if os(iOS)
        // Recordings are readable while the device is locked (a recording may continue
        // with the screen off) but encrypted until the first unlock after boot.
        try (recordingsDirectory as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication,
            forKey: .fileProtectionKey
        )
        #endif
    }

    func audioURL(fileName: String) -> URL {
        recordingsDirectory.appending(path: fileName, directoryHint: .notDirectory)
    }

    /// Controls whether the app's data is part of iCloud / computer backups.
    /// Downloaded models are always excluded because they can be downloaded again.
    func setIncludedInBackup(_ included: Bool) throws {
        var rootURL = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = !included
        try rootURL.setResourceValues(values)

        var modelsURL = whisperModelsDirectory
        var modelValues = URLResourceValues()
        modelValues.isExcludedFromBackup = true
        try modelsURL.setResourceValues(modelValues)
    }

    /// Free space on the volume holding `url` for data the user asked to keep, in bytes.
    /// `nil` if the volume does not report it.
    ///
    /// Declared in the privacy manifest (disk space, reason E174.1): checked only before and
    /// while writing a recording, so it neither starts nor runs into a full disk.
    static func availableCapacity(at url: URL) -> Int64? {
        DiskSpace.available(at: url)
    }

    /// Total size of all regular files below `directory`, in bytes.
    static func allocatedSize(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
