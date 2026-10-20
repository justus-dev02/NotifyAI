//
//  NoteLibrary.swift
//  NotifyAILibrary
//

import Foundation
import NotifyAICore
import NotifyAIPersistence
import NotifyAIProcessing
import NotifyAISupport
import Observation
import SwiftData

/// The changes a user makes to notes: favorites, titles, markers, tasks, deleting notes or
/// only their recording or transcript.
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

    package init(store: NoteStore, processing: ProcessingCoordinator) {
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

    /// Adds a marker, e.g. at the playback position. A marker at the same moment as an
    /// existing one is ignored.
    public func addMarker(_ marker: Marker, to note: Note) {
        let markers = note.markers.adding(marker)
        guard markers.count != note.markers.count else { return }
        note.markers = markers
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

    // MARK: Tasks

    /// Adds a task of the user's own to the note. Summarizing again keeps it.
    /// - Returns: `false` for an empty task, which is ignored, or when it could not be saved.
    @discardableResult
    public func addTask(_ draft: TaskDraft, to note: Note) -> Bool {
        guard let fields = draft.fields() else { return false }
        _ = note.appendTask(fields.task, owner: fields.owner, due: fields.due, dueDate: fields.dueDate)
        return store.saveReportingErrors()
    }

    /// Changes a task's text, owner or due date. From now on the task is the user's:
    /// summarizing again keeps it as it is.
    /// - Returns: `false` for an empty task, an unknown one or when it could not be saved.
    @discardableResult
    public func updateTask(_ id: ActionItem.ID, with draft: TaskDraft) -> Bool {
        guard let fields = draft.fields(), let task = task(id: id), let note = task.note else { return false }
        note.editTask(task, task: fields.task, owner: fields.owner, due: fields.due, dueDate: fields.dueDate)
        return store.saveReportingErrors()
    }

    /// Removes a task from its note.
    @discardableResult
    public func deleteTask(_ id: ActionItem.ID) -> Bool {
        guard let task = task(id: id), let note = task.note else { return false }
        note.removeTask(task)
        return store.saveReportingErrors()
    }

    private func task(id: ActionItem.ID) -> NoteTask? {
        var descriptor = FetchDescriptor<NoteTask>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return store.fetch(descriptor).first
    }

    // MARK: Deleting

    /// Whether the note's audio can be deleted now: it has an audio file and is neither being
    /// recorded nor processed (transcription and speaker detection read the file).
    public func canDeleteAudio(of note: Note) -> Bool {
        note.hasAudioFile && note.status != .recording && !note.status.isProcessing
    }

    /// Deletes only the recordings of the notes, to free space. Transcript, summary, tasks
    /// and speakers stay; the notes can no longer be played or transcribed again. Notes whose
    /// audio cannot be deleted now (see `canDeleteAudio`) are left out.
    /// - Returns: Whether the change was saved.
    @discardableResult
    public func deleteAudio(of notes: [Note]) -> Bool {
        let deletable = notes.filter(canDeleteAudio)
        guard !deletable.isEmpty else { return true }
        do {
            try store.removeAudio(of: deletable)
            return true
        } catch {
            store.events.send(.saveFailed(error))
            return false
        }
    }

    /// The notes whose recording can be deleted, newest first: all of them, or those recorded
    /// before `cutoff`. Favorites only when asked for.
    public func notesWithAudio(recordedBefore cutoff: Date? = nil, includingFavorites: Bool = true) -> [Note] {
        let latest = cutoff ?? .distantFuture
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { $0.audioFileName != nil && $0.createdAt < latest },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return store.fetch(descriptor).filter { canDeleteAudio(of: $0) && (includingFavorites || !$0.isFavorite) }
    }

    /// The space the recordings of the notes take, in bytes.
    public func audioSize(of notes: [Note]) async -> Int64 {
        let urls = notes.compactMap(store.audioURL(for:))
        return await Self.allocatedSize(of: urls)
    }

    /// Whether the transcript can be deleted now: the note has one and is not being processed.
    public func canDeleteTranscript(of note: Note) -> Bool {
        note.hasTranscript && note.status != .recording && !note.status.isProcessing
    }

    /// Deletes the transcript and its speakers. Summary, tasks, markers and the recording
    /// stay; with the recording the note can be transcribed again.
    /// - Returns: Whether the change was saved.
    @discardableResult
    public func deleteTranscript(of note: Note) -> Bool {
        guard canDeleteTranscript(of: note) else { return false }
        note.clearTranscript()
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

    @concurrent
    private static func allocatedSize(of urls: [URL]) async -> Int64 {
        urls.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
    }
}

/// A task as the user enters or changes it.
public struct TaskDraft: Equatable, Sendable {
    public var task: String
    public var owner: String
    /// The day it is due; `nil` without a deadline.
    public var dueDate: Date?
    /// The deadline as it was said ("bis Freitag"), kept while `dueDate` is unchanged.
    var spokenDue: String?
    private var spokenDueDate: Date?

    public init(task: String = "", owner: String = "", dueDate: Date? = nil) {
        self.task = task
        self.owner = owner
        self.dueDate = dueDate
    }

    /// The fields of an existing task, to change them.
    @MainActor
    public init(_ task: NoteTask) {
        self.init(task: task.task, owner: task.owner ?? "", dueDate: task.dueDate)
        spokenDue = task.due
        spokenDueDate = task.dueDate
    }

    /// The trimmed values to store; `nil` for an empty task. A deadline that was said keeps its
    /// words while the date stays the same; a date the user chose is written as a date.
    func fields(calendar: Calendar = .current) -> (task: String, owner: String?, due: String?, dueDate: Date?)? {
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return nil }
        let owner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let day = dueDate.map { calendar.startOfDay(for: $0) }
        let due: String? = if let day {
            spokenDue.flatMap { spoken in spokenDueDate.map { calendar.isDate($0, inSameDayAs: day) } == true ? spoken : nil }
                ?? Self.dueText(for: day, calendar: calendar)
        } else {
            nil
        }
        return (task, owner.isEmpty ? nil : owner, due, day)
    }

    /// "24. Oktober", with the year when it is not this year's.
    static func dueText(for day: Date, calendar: Calendar, now: Date = .now) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .omitted, calendar: calendar, timeZone: calendar.timeZone).day().month(.wide)
        if calendar.component(.year, from: day) != calendar.component(.year, from: now) {
            style = style.year()
        }
        return day.formatted(style)
    }
}
