//
//  TaskBoard.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore
import NotifyAIPersistence
import Observation
import SwiftData

/// All tasks of all summaries, kept up to date for the overview and its count.
///
/// Tasks are rows of their own (`NoteTask`) with the due date resolved when the summary was
/// saved, so a refresh is one query; no summary is decoded. The board refreshes after every
/// save or deletion of the store (`NoteStore.events`), coalesced, and never while nobody
/// asked for it.
@MainActor
@Observable
public final class TaskBoard {
    public private(set) var entries: [TaskEntry] = []

    public var openCount: Int { entries.count { !$0.item.isDone } }

    /// Everybody who owns at least one task, with the number of open tasks, most first.
    public var owners: [(key: String, name: String, openCount: Int)] {
        var names: [String: String] = [:]
        var counts: [String: Int] = [:]
        for entry in entries {
            guard let owner = entry.item.owner, let key = entry.ownerKey else { continue }
            names[key] = names[key] ?? owner
            counts[key, default: 0] += entry.item.isDone ? 0 : 1
        }
        return names.map { (key: $0.key, name: $0.value, openCount: counts[$0.key] ?? 0) }
            .sorted { $0.openCount != $1.openCount ? $0.openCount > $1.openCount : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let library: NoteLibrary
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    @ObservationIgnored private var subscription: EventSubscription?

    init(store: NoteStore, library: NoteLibrary) {
        self.store = store
        self.library = library
    }

    /// Starts following the store's saves and deletions.
    func startObserving() {
        guard subscription == nil else { return }
        subscription = store.events.subscribe { [weak self] event in
            switch event {
            case .saved, .deleted:
                self?.scheduleRefresh()
            case .saveFailed, .deleteFailed:
                break
            }
        }
        refresh()
    }

    /// Several saves in a row (processing a note) cause one refresh.
    func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func refresh() {
        let tasks = store.fetch(FetchDescriptor<NoteTask>(predicate: #Predicate { $0.note != nil }))
        let all = tasks.compactMap { task -> TaskEntry? in
            guard let note = task.note else { return nil }
            return TaskEntry(
                noteID: note.id,
                noteTitle: note.title,
                noteCreatedAt: note.createdAt,
                item: task.actionItem,
                dueDate: task.dueDate,
                sourceTime: task.sourceTime
            )
        }
        .sorted(by: Self.order)
        if all != entries {
            entries = all
        }
    }

    /// Ticks a task off or reopens it. The list shows the change at once; the store's save
    /// confirms it with the next refresh.
    public func setDone(_ entry: TaskEntry, _ isDone: Bool) {
        guard library.setTask(entry.id, isDone: isDone) else { return }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].item.isDone = isDone
        }
    }

    // MARK: - Private

    /// Earliest due date first, tasks without a date last; newer notes first otherwise.
    private static func order(_ lhs: TaskEntry, _ rhs: TaskEntry) -> Bool {
        switch (lhs.dueDate, rhs.dueDate) {
        case let (left?, right?) where left != right: return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        default:
            if lhs.noteCreatedAt != rhs.noteCreatedAt { return lhs.noteCreatedAt > rhs.noteCreatedAt }
            return lhs.item.task < rhs.item.task
        }
    }
}
