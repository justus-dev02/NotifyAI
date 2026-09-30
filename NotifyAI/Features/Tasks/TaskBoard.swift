//
//  TaskBoard.swift
//  NotifyAI
//

import Foundation
import NotifyAICore
import Observation
import OSLog
import SwiftData

/// One task from a note's summary, with what the overview needs to show, filter and open it.
struct TaskEntry: Identifiable, Hashable, Sendable {
    var id: ActionItem.ID { item.id }
    let noteID: UUID
    let noteTitle: String
    let noteCreatedAt: Date
    var item: ActionItem
    /// The day the task is due, resolved from the spoken deadline.
    let dueDate: Date?
    /// Where the task was mentioned in the recording.
    let sourceTime: TimeInterval?

    /// Normalized owner for filtering; `nil` when nobody was named.
    var ownerKey: String? { item.owner.flatMap(TaskEntry.ownerKey(for:)) }

    static func ownerKey(for owner: String) -> String? {
        let key = TextAnalysis.key(owner)
        return key.isEmpty ? nil : key
    }
}

/// When a task is due, as shown in the overview's sections.
enum TaskDueBucket: Int, CaseIterable, Identifiable, Sendable {
    case overdue
    case today
    case thisWeek
    case later
    case noDate

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .overdue: String(localized: "Überfällig")
        case .today: String(localized: "Heute")
        case .thisWeek: String(localized: "Diese Woche")
        case .later: String(localized: "Später")
        case .noDate: String(localized: "Ohne Termin")
        }
    }

    static func bucket(for dueDate: Date?, now: Date, calendar: Calendar = .current) -> TaskDueBucket {
        guard let dueDate else { return .noDate }
        let today = calendar.startOfDay(for: now)
        if dueDate < today { return .overdue }
        if calendar.isDate(dueDate, inSameDayAs: today) { return .today }
        if let week = calendar.dateInterval(of: .weekOfYear, for: today), week.contains(dueDate) { return .thisWeek }
        return .later
    }
}

/// Filters of the task overview.
struct TaskFilter: Equatable {
    enum Owner: Hashable {
        case everyone
        case unassigned
        case person(key: String)
    }

    var owner: Owner = .everyone
    /// `nil` shows every due date.
    var due: TaskDueBucket?
    var showsDone = false

    var isActive: Bool { owner != .everyone || due != nil || showsDone }

    func matches(_ entry: TaskEntry, now: Date, calendar: Calendar = .current) -> Bool {
        if !showsDone, entry.item.isDone { return false }
        switch owner {
        case .everyone: break
        case .unassigned: if entry.ownerKey != nil { return false }
        case .person(let key): if entry.ownerKey != key { return false }
        }
        if let due, TaskDueBucket.bucket(for: entry.dueDate, now: now, calendar: calendar) != due { return false }
        return true
    }
}

/// All tasks of all summaries, kept up to date for the overview and its count.
///
/// Summaries are small JSON blobs in the note rows. A refresh reads them and decodes only
/// those that changed since the last refresh (compared by content hash), so keeping the
/// board current costs little even with hundreds of notes. It refreshes after every save
/// of the store (`ModelContext.didSave`), coalesced, and never while nobody asked for it.
@MainActor
@Observable
final class TaskBoard {
    private(set) var entries: [TaskEntry] = []

    var openCount: Int { entries.count { !$0.item.isDone } }

    /// Everybody who owns at least one task, with the number of open tasks, most first.
    var owners: [(key: String, name: String, openCount: Int)] {
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
    @ObservationIgnored private let resolver: DueDateResolver
    /// Decoded tasks per note, with the hash of the summary data and the title they came from.
    @ObservationIgnored private var cache: [UUID: (signature: Int, entries: [TaskEntry])] = [:]
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    @ObservationIgnored private var saveObserver: Task<Void, Never>?

    init(store: NoteStore, resolver: DueDateResolver = DueDateResolver()) {
        self.store = store
        self.resolver = resolver
    }

    /// Starts following the store's saves.
    func startObserving() {
        guard saveObserver == nil else { return }
        // Only the identity of the saving context crosses into the task.
        let ownContext = ObjectIdentifier(store.context)
        let saves = NotificationCenter.default.notifications(named: ModelContext.didSave)
            .map { notification in (notification.object as AnyObject?).map(ObjectIdentifier.init) }
        saveObserver = Task { [weak self] in
            for await context in saves where context == ownContext {
                self?.scheduleRefresh()
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
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { $0.summaryData != nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let notes: [Note]
        do {
            notes = try store.context.fetch(descriptor)
        } catch {
            Logger.persistence.error("Loading tasks failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        var updatedCache: [UUID: (signature: Int, entries: [TaskEntry])] = [:]
        for note in notes {
            guard let data = note.summaryData else { continue }
            var hasher = Hasher()
            hasher.combine(data)
            hasher.combine(note.title)
            let signature = hasher.finalize()
            if let cached = cache[note.id], cached.signature == signature {
                updatedCache[note.id] = cached
            } else {
                updatedCache[note.id] = (signature, makeEntries(for: note))
            }
        }
        cache = updatedCache
        let all = updatedCache.values.flatMap(\.entries).sorted(by: Self.order)
        if all != entries {
            entries = all
        }
    }

    /// Ticks a task off or reopens it.
    func setDone(_ entry: TaskEntry, _ isDone: Bool) {
        guard let note = store.note(id: entry.noteID), note.setActionItem(entry.id, isDone: isDone) else { return }
        store.saveReportingErrors()
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].item.isDone = isDone
        }
    }

    // MARK: - Private

    private func makeEntries(for note: Note) -> [TaskEntry] {
        guard let summary = note.summary else { return [] }
        return summary.actionItems.map { item in
            TaskEntry(
                noteID: note.id,
                noteTitle: note.title,
                noteCreatedAt: note.createdAt,
                item: item,
                dueDate: item.due.flatMap { resolver.resolve($0, relativeTo: note.createdAt) },
                sourceTime: summary.sourceTimes[item.task]
            )
        }
    }

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
