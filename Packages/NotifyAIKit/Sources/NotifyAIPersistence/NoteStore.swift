//
//  NoteStore.swift
//  NotifyAIPersistence
//

import Foundation
import NotifyAICore
import OSLog
import SwiftData

/// What happened in the store. Listeners subscribe to `NoteStore.events`.
public enum NoteStoreEvent: Sendable {
    /// Changes were written. Contains the notes that were inserted or changed (including
    /// changes of their content and tasks); deletions are reported by `.deleted`.
    case saved(changedNoteIDs: Set<UUID>)
    /// Notes were deleted and the deletion was written.
    case deleted([UUID])
    /// A change could not be written. Nothing threw to the caller; the app shows it.
    case saveFailed(any Error)
    /// A note could not be deleted.
    case deleteFailed(any Error)
}

/// Owns the SwiftData container and performs all note mutations.
///
/// The store works on the main context. Heavy work (transcription, summarization, JSON
/// encoding of long transcripts) happens elsewhere; only the small, final writes go through
/// here, which keeps SwiftData usage single-threaded and simple.
///
/// Access control is the layering rule: reading (the container for `@Query`, file locations)
/// is `public`; every write is `package`, so only the services of this package can change
/// notes. The app changes notes through use cases such as `NoteLibrary`, never directly.
@MainActor
public final class NoteStore {
    public let container: ModelContainer
    public let locations: StorageLocations
    /// Saves, deletions and failures, for the search index, the task board and the app.
    public let events = EventChannel<NoteStoreEvent>()
    private let logger = Logger.persistence

    package var context: ModelContext { container.mainContext }

    public init(locations: StorageLocations, inMemory: Bool = false) throws {
        self.locations = locations
        let schema = Schema(versionedSchema: NotifyAISchemaV4.self)
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
        // Every write goes through `save()`, which reports what changed. Autosave would
        // write changes without telling the listeners.
        container.mainContext.autosaveEnabled = false
    }

    // MARK: Queries

    package func note(id: UUID) -> Note? {
        var descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return fetch(descriptor).first
    }

    package func notes(withStatus statuses: [NoteStatus]) -> [Note] {
        let rawValues = statuses.map(\.rawValue)
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { rawValues.contains($0.statusRawValue) },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return fetch(descriptor)
    }

    /// Runs a query and logs failures; a failed fetch behaves like an empty result.
    package func fetch<Model: PersistentModel>(_ descriptor: FetchDescriptor<Model>) -> [Model] {
        do {
            return try context.fetch(descriptor)
        } catch {
            logger.error("Fetching \(String(describing: Model.self), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// The audio file of a note, if it has one.
    public func audioURL(for note: Note) -> URL? {
        note.audioFileName.map(locations.audioURL(fileName:))
    }

    // MARK: Mutations

    package func insert(_ note: Note) throws {
        context.insert(note)
        try save()
    }

    /// Persists pending changes and reports them through `events`. Errors are logged and
    /// rethrown so callers can handle them.
    package func save() throws {
        guard context.hasChanges else { return }
        let changed = changedNoteIDs()
        do {
            try context.save()
        } catch {
            logger.error("Saving the store failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        if !changed.isEmpty {
            events.send(.saved(changedNoteIDs: changed))
        }
    }

    /// Saves and reports a failure through `events` instead of throwing.
    /// - Returns: Whether the changes were written.
    @discardableResult
    package func saveReportingErrors() -> Bool {
        do {
            try save()
            return true
        } catch {
            events.send(.saveFailed(error))
            return false
        }
    }

    /// Deletes the note and reports a failure through `events` instead of throwing.
    @discardableResult
    package func deleteReportingErrors(_ note: Note) -> Bool {
        do {
            try delete(note)
            return true
        } catch {
            logger.error("Deleting a note failed: \(error.localizedDescription, privacy: .public)")
            events.send(.deleteFailed(error))
            return false
        }
    }

    /// Deletes the note together with its audio file. The file is removed only after the
    /// deletion was saved, so a failed save never leaves a note without its audio.
    package func delete(_ note: Note) throws {
        try delete([note])
    }

    package func deleteAll() throws {
        try delete(try context.fetch(FetchDescriptor<Note>()))
    }

    private func delete(_ notes: [Note]) throws {
        guard !notes.isEmpty else { return }
        let ids = notes.map(\.id)
        let urls = notes.compactMap(audioURL(for:))
        // Other pending changes are written together with the deletion and reported as usual.
        let changed = changedNoteIDs().subtracting(ids)
        for note in notes {
            context.delete(note)
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            logger.error("Saving a deletion failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        urls.forEach(removeFileIfPresent(at:))
        if !changed.isEmpty {
            events.send(.saved(changedNoteIDs: changed))
        }
        events.send(.deleted(ids))
    }

    /// Copies an external audio file into the recordings directory.
    /// - Returns: The file name to store on the note.
    package func importAudioFile(from source: URL, noteID: UUID) throws -> String {
        let fileExtension = source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased()
        let fileName = "\(noteID.uuidString).\(fileExtension)"
        let destination = locations.audioURL(fileName: fileName)
        removeFileIfPresent(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        return fileName
    }

    package static func recordingFileName(for noteID: UUID) -> String {
        "\(noteID.uuidString).\(AudioFormat.recordingFileExtension)"
    }

    // MARK: - Private

    /// The notes affected by the pending changes: changed notes and notes whose content
    /// changed. Read before saving; afterwards the context has no pending changes.
    private func changedNoteIDs() -> Set<UUID> {
        var ids = Set<UUID>()
        for model in context.insertedModelsArray + context.changedModelsArray {
            if let note = model as? Note {
                ids.insert(note.id)
            } else if let content = model as? NoteContent, let note = content.note {
                ids.insert(note.id)
            } else if let task = model as? NoteTask, let note = task.note {
                ids.insert(note.id)
            }
        }
        return ids
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
