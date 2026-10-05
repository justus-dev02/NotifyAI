//
//  NoteLibrary.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore
import NotifyAIPersistence
import Observation
import SwiftData

/// The changes a user makes to notes: favorites, titles, markers, tasks, deleting.
///
/// This is the app's only way to change a note. Models are read-only outside this package
/// (`public package(set)`), so a view cannot write a model and forget to save, and every
/// change reaches the listeners of `NoteStore.events` (search index, task board). Failures
/// are reported through those events too; the app shows them as notices.
@MainActor
@Observable
public final class NoteLibrary {
    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let processing: ProcessingCoordinator

    init(store: NoteStore, processing: ProcessingCoordinator) {
        self.store = store
        self.processing = processing
    }

    public func setFavorite(_ isFavorite: Bool, for note: Note) {
        guard note.isFavorite != isFavorite else { return }
        note.isFavorite = isFavorite
        store.saveReportingErrors()
    }

    /// Gives the note a title of the user's choice; automatic titles no longer replace it.
    /// - Returns: `false` for an empty title, which is ignored.
    @discardableResult
    public func rename(_ note: Note, to title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        note.title = trimmed
        note.isTitleUserDefined = true
        store.saveReportingErrors()
        return true
    }

    /// Adds a marker, e.g. at the playback position.
    public func addMarker(_ marker: Marker, to note: Note) {
        note.markers += [marker]
        store.saveReportingErrors()
    }

    /// Ticks a task off or reopens it. Only the task's row changes; the summary, and with it
    /// the search index, stays as it is.
    /// - Returns: Whether the task exists and the change was saved.
    @discardableResult
    public func setTask(_ id: ActionItem.ID, isDone: Bool) -> Bool {
        var descriptor = FetchDescriptor<NoteTask>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let task = store.fetch(descriptor).first else { return false }
        guard task.isDone != isDone else { return true }
        task.isDone = isDone
        return store.saveReportingErrors()
    }

    /// Stops processing the note and deletes it with its audio file.
    public func delete(_ note: Note) {
        processing.cancel(noteID: note.id)
        store.deleteReportingErrors(note)
    }

    /// Stops all processing and deletes every note.
    /// - Throws: When the deletion could not be written; nothing was deleted then.
    public func deleteAll() throws {
        processing.cancelAll()
        try store.deleteAll()
    }

    /// The audio file of a note, if it has one.
    public func audioURL(for note: Note) -> URL? {
        store.audioURL(for: note)
    }
}
