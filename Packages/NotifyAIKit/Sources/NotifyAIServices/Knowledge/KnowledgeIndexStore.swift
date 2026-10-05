//
//  KnowledgeIndexStore.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore
import OSLog

/// Where the search index is kept. Implemented by `KnowledgeIndexStore`; tests can record
/// what is written.
protocol KnowledgeIndexPersisting: Sendable {
    /// All stored notes, or an empty index when the stored format is outdated.
    func load() async -> KnowledgeIndex
    func save(_ note: IndexedNote) async
    func remove(_ noteIDs: [UUID]) async
    func removeAll() async
}

/// Stores the search index on disk, one file per note.
///
/// Indexing a note writes only that note's file (a few KB to a few hundred KB) instead of
/// the whole index, so the cost of an update does not grow with the number of notes.
/// A manifest records the format version; an index in an older format is discarded and
/// rebuilt. Files are loaded in parallel at launch.
actor KnowledgeIndexStore: KnowledgeIndexPersisting {
    private struct Manifest: Codable {
        var formatVersion: Int
    }

    private let directory: URL
    /// The single-file index of earlier versions, removed on first launch.
    private let legacyFile: URL?
    private let logger = Logger.processing
    private let encoder: PropertyListEncoder = {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }()

    init(directory: URL, legacyFile: URL? = nil) {
        self.directory = directory
        self.legacyFile = legacyFile
    }

    /// All stored notes, or an empty index when the stored format is outdated.
    func load() async -> KnowledgeIndex {
        if let legacyFile {
            try? FileManager.default.removeItem(at: legacyFile)
        }
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? PropertyListDecoder().decode(Manifest.self, from: manifestData),
              manifest.formatVersion == KnowledgeIndex.formatVersion
        else {
            removeAll()
            return KnowledgeIndex()
        }

        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let noteFiles = files.filter { $0.pathExtension == "plist" && $0 != manifestURL }
        let notes = await withTaskGroup(of: IndexedNote?.self) { group in
            for file in noteFiles {
                group.addTask {
                    guard let data = try? Data(contentsOf: file) else { return nil }
                    return try? PropertyListDecoder().decode(IndexedNote.self, from: data)
                }
            }
            var notes: [UUID: IndexedNote] = [:]
            for await note in group {
                if let note { notes[note.id] = note }
            }
            return notes
        }
        return KnowledgeIndex(notes: notes)
    }

    func save(_ note: IndexedNote) {
        do {
            try ensureManifest()
            try write(try encoder.encode(note), to: fileURL(for: note.id))
        } catch {
            logger.error("Saving an index entry failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func remove(_ noteIDs: [UUID]) {
        for id in noteIDs {
            try? FileManager.default.removeItem(at: fileURL(for: id))
        }
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Private

    private var manifestURL: URL {
        directory.appending(path: "manifest.plist", directoryHint: .notDirectory)
    }

    private func fileURL(for noteID: UUID) -> URL {
        directory.appending(path: "\(noteID.uuidString).plist", directoryHint: .notDirectory)
    }

    private func ensureManifest() throws {
        guard !FileManager.default.fileExists(atPath: manifestURL.path(percentEncoded: false)) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(try encoder.encode(Manifest(formatVersion: KnowledgeIndex.formatVersion)), to: manifestURL)
    }

    private func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        // Contains transcript text: protected like the recordings.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}
