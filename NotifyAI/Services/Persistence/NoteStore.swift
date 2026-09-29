//
//  NoteStore.swift
//  NotifyAI
//

import Foundation
import OSLog
import SwiftData

/// Owns the SwiftData container and performs all note mutations.
///
/// The store works on the main context. Heavy work (transcription, summarization,
/// JSON encoding of long transcripts) happens elsewhere; only the small, final
/// writes go through here, which keeps SwiftData usage single-threaded and simple.
@MainActor
final class NoteStore {
    let container: ModelContainer
    let locations: StorageLocations
    private let logger = Logger.persistence

    var context: ModelContext { container.mainContext }

    init(locations: StorageLocations, inMemory: Bool = false) throws {
        self.locations = locations
        let schema = Schema(versionedSchema: NotifyAISchemaV2.self)
        let configuration: ModelConfiguration = if inMemory {
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else {
            // `.none` keeps the database strictly local, even if iCloud is enabled later.
            ModelConfiguration(schema: schema, url: locations.databaseURL, cloudKitDatabase: .none)
        }
        container = try ModelContainer(
            for: schema,
            migrationPlan: NotifyAIMigrationPlan.self,
            configurations: configuration
        )
    }

    // MARK: Queries

    func note(id: UUID) -> Note? {
        var descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func notes(withStatus statuses: [NoteStatus]) -> [Note] {
        let rawValues = statuses.map(\.rawValue)
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { rawValues.contains($0.statusRawValue) },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func audioURL(for note: Note) -> URL? {
        note.audioFileName.map(locations.audioURL(fileName:))
    }

    // MARK: Mutations

    func insert(_ note: Note) throws {
        context.insert(note)
        try save()
    }

    /// Persists pending changes. Errors are logged and rethrown so callers can surface them.
    func save() throws {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            logger.error("Saving the store failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Deletes the note together with its audio file.
    func delete(_ note: Note) throws {
        if let url = audioURL(for: note) {
            removeFileIfPresent(at: url)
        }
        context.delete(note)
        try save()
    }

    func deleteAll() throws {
        let all = try context.fetch(FetchDescriptor<Note>())
        for note in all {
            if let url = audioURL(for: note) {
                removeFileIfPresent(at: url)
            }
            context.delete(note)
        }
        try save()
    }

    /// Copies an external audio file into the recordings directory.
    /// - Returns: The file name to store on the note.
    func importAudioFile(from source: URL, noteID: UUID) throws -> String {
        let fileExtension = source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased()
        let fileName = "\(noteID.uuidString).\(fileExtension)"
        let destination = locations.audioURL(fileName: fileName)
        removeFileIfPresent(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        return fileName
    }

    static func recordingFileName(for noteID: UUID) -> String {
        "\(noteID.uuidString).\(AudioFormat.recordingFileExtension)"
    }

    private func removeFileIfPresent(at url: URL) {
        do {
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            logger.error("Removing \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
