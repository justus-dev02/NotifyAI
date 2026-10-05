//
//  TaskEntry.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore

/// One task from a note's summary, with what the overview needs to show, filter and open it.
public struct TaskEntry: Identifiable, Hashable, Sendable {
    public var id: ActionItem.ID { item.id }
    public let noteID: UUID
    public let noteTitle: String
    public let noteCreatedAt: Date
    public var item: ActionItem
    /// The day the task is due, resolved from the spoken deadline.
    public let dueDate: Date?
    /// Where the task was mentioned in the recording.
    public let sourceTime: TimeInterval?

    /// Normalized owner for filtering; `nil` when nobody was named.
    var ownerKey: String? { item.owner.flatMap(Self.ownerKey(for:)) }

    static func ownerKey(for owner: String) -> String? {
        let key = TextAnalysis.key(owner)
        return key.isEmpty ? nil : key
    }
}

/// When a task is due, as shown in the overview's sections.
public enum TaskDueBucket: Int, CaseIterable, Identifiable, Sendable {
    case overdue
    case today
    case thisWeek
    case later
    case noDate

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .overdue: String(localized: "Überfällig", bundle: .module)
        case .today: String(localized: "Heute", bundle: .module)
        case .thisWeek: String(localized: "Diese Woche", bundle: .module)
        case .later: String(localized: "Später", bundle: .module)
        case .noDate: String(localized: "Ohne Termin", bundle: .module)
        }
    }

    public static func bucket(for dueDate: Date?, now: Date, calendar: Calendar = .current) -> Self {
        guard let dueDate else { return .noDate }
        let today = calendar.startOfDay(for: now)
        if dueDate < today { return .overdue }
        if calendar.isDate(dueDate, inSameDayAs: today) { return .today }
        if let week = calendar.dateInterval(of: .weekOfYear, for: today), week.contains(dueDate) { return .thisWeek }
        return .later
    }
}

/// Filters of the task overview.
public struct TaskFilter: Equatable {
    public enum Owner: Hashable {
        case everyone
        case unassigned
        case person(key: String)
    }

    public var owner: Owner = .everyone
    /// `nil` shows every due date.
    public var due: TaskDueBucket?
    public var showsDone = false

    public init(owner: Owner = .everyone, due: TaskDueBucket? = nil, showsDone: Bool = false) {
        self.owner = owner
        self.due = due
        self.showsDone = showsDone
    }

    public var isActive: Bool { owner != .everyone || due != nil || showsDone }

    public func matches(_ entry: TaskEntry, now: Date, calendar: Calendar = .current) -> Bool {
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
