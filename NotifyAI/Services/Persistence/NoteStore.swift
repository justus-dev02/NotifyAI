//
//  NoteStore.swift
//  NotifyAI
//

import AVFoundation
import Foundation
import NotifyAICore
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

    /// Called after notes were deleted, e.g. to remove them from the search index.
    var onNotesDeleted: (([UUID]) -> Void)?
    /// Called with a user-facing message when a change could not be written. Every write
    /// that does not surface its error to the caller goes through `saveReportingErrors()`
    /// or `deleteReportingErrors(_:)`, so no failure is lost silently.
    var onFailure: ((String) -> Void)?

    var context: ModelContext { container.mainContext }

    init(locations: StorageLocations, inMemory: Bool = false) throws {
        self.locations = locations
        let schema = Schema(versionedSchema: NotifyAISchemaV3.self)
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
        return fetch(descriptor).first
    }

    func notes(withStatus statuses: [NoteStatus]) -> [Note] {
        let rawValues = statuses.map(\.rawValue)
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { rawValues.contains($0.statusRawValue) },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return fetch(descriptor)
    }

    /// Fetches and logs failures; a failed fetch behaves like an empty result.
    private func fetch(_ descriptor: FetchDescriptor<Note>) -> [Note] {
        do {
            return try context.fetch(descriptor)
        } catch {
            logger.error("Fetching notes failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
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

    /// Saves and reports a failure through `onFailure` instead of throwing.
    /// - Returns: Whether the changes were written.
    @discardableResult
    func saveReportingErrors() -> Bool {
        do {
            try save()
            return true
        } catch {
            onFailure?(String(localized: "Die Änderung konnte nicht gespeichert werden: \(error.localizedDescription)"))
            return false
        }
    }

    /// Deletes the note and reports a failure through `onFailure` instead of throwing.
    @discardableResult
    func deleteReportingErrors(_ note: Note) -> Bool {
        do {
            try delete(note)
            return true
        } catch {
            logger.error("Deleting a note failed: \(error.localizedDescription, privacy: .public)")
            onFailure?(String(localized: "Die Notiz konnte nicht gelöscht werden: \(error.localizedDescription)"))
            return false
        }
    }

    /// Deletes the note together with its audio file. The file is removed only after the
    /// deletion was saved, so a failed save never leaves a note without its audio.
    func delete(_ note: Note) throws {
        let url = audioURL(for: note)
        let id = note.id
        context.delete(note)
        do {
            try save()
        } catch {
            context.rollback()
            throw error
        }
        if let url {
            removeFileIfPresent(at: url)
        }
        onNotesDeleted?([id])
    }

    func deleteAll() throws {
        let all = try context.fetch(FetchDescriptor<Note>())
        let ids = all.map(\.id)
        let urls = all.compactMap(audioURL(for:))
        for note in all {
            context.delete(note)
        }
        do {
            try save()
        } catch {
            context.rollback()
            throw error
        }
        urls.forEach(removeFileIfPresent(at:))
        onNotesDeleted?(ids)
    }

    /// Audio files in the recordings folder that could belong to a note.
    static let recoverableAudioExtensions: Set<String> = ["caf", "m4a", "mp3", "wav", "aif", "aiff", "aac", "mp4"]

    /// Creates notes for audio files in the recordings folder that no note refers to, e.g.
    /// after the database had to be reset. They are queued, so processing transcribes and
    /// summarizes them again. Recordings (CAF) are readable even if the app was killed while
    /// recording them.
    /// - Returns: The identifiers of the recovered notes.
    @discardableResult
    func recoverOrphanedRecordings() async throws -> [UUID] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .creationDateKey]
        let files = try FileManager.default.contentsOfDirectory(at: locations.recordingsDirectory, includingPropertiesForKeys: Array(keys))
        let referenced = Set(try context.fetch(FetchDescriptor<Note>()).compactMap(\.audioFileName))
        var recovered: [UUID] = []

        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let fileExtension = file.pathExtension.lowercased()
            guard !referenced.contains(file.lastPathComponent),
                  Self.recoverableAudioExtensions.contains(fileExtension),
                  let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true
            else { continue }

            let duration = (try? await AVURLAsset(url: file).load(.duration).seconds) ?? 0
            let createdAt = values.creationDate ?? .now
            let isRecording = fileExtension == AudioFormat.recordingFileExtension
            let kind: NoteKind = isRecording ? .recording : .audioImport
            let note = Note(
                id: UUID(uuidString: file.deletingPathExtension().lastPathComponent) ?? UUID(),
                title: Note.automaticTitle(for: kind, date: createdAt),
                isTitleUserDefined: false,
                createdAt: createdAt,
                kind: kind,
                status: .queued,
                audioFileName: file.lastPathComponent
            )
            note.duration = duration.isFinite ? duration : 0
            context.insert(note)
            recovered.append(note.id)
        }
        try save()
        if !recovered.isEmpty {
            logger.info("Recovered \(recovered.count, privacy: .public) recordings without a note")
        }
        return recovered
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
