//
//  TaskTests.swift
//  NotifyAITests
//
//  Due dates from spoken deadlines, the grouping and filters of the task overview and the
//  task board that collects tasks from all summaries.
//

import Foundation
@testable import NotifyAI
import NotifyAICore
@testable import NotifyAIPersistence
@testable import NotifyAIServices
import Testing

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    calendar.firstWeekday = 2
    return calendar
}()

private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

/// Wednesday, 30 September 2026, in the afternoon.
private let recordedAt = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 15))!

@Suite("Task overview")
@MainActor
struct TaskOverviewTests {
    @Test("Tasks fall into overdue, today, this week, later and without date")
    func buckets() {
        let now = recordedAt
        #expect(TaskDueBucket.bucket(for: day(2026, 9, 29), now: now, calendar: calendar) == .overdue)
        #expect(TaskDueBucket.bucket(for: day(2026, 9, 30), now: now, calendar: calendar) == .today)
        #expect(TaskDueBucket.bucket(for: day(2026, 10, 2), now: now, calendar: calendar) == .thisWeek)
        #expect(TaskDueBucket.bucket(for: day(2026, 10, 9), now: now, calendar: calendar) == .later)
        #expect(TaskDueBucket.bucket(for: nil, now: now, calendar: calendar) == .noDate)
    }

    private func entry(_ task: String, owner: String?, due: Date?, done: Bool = false) -> TaskEntry {
        TaskEntry(noteID: UUID(), noteTitle: "N", noteCreatedAt: recordedAt,
                  item: ActionItem(task: task, owner: owner, isDone: done), dueDate: due, sourceTime: nil)
    }

    @Test("Filters combine person, due date and done tasks")
    func filters() {
        let anna = entry("A", owner: "Anna", due: day(2026, 10, 2))
        let annaDone = entry("B", owner: "anna", due: nil, done: true)
        let nobody = entry("C", owner: nil, due: day(2026, 9, 29))

        var filter = TaskFilter()
        #expect([anna, annaDone, nobody].filter { filter.matches($0, now: recordedAt, calendar: calendar) }.map(\.item.task) == ["A", "C"])

        filter.owner = .person(key: try! #require(TaskEntry.ownerKey(for: "Anna")))
        filter.showsDone = true
        #expect([anna, annaDone, nobody].filter { filter.matches($0, now: recordedAt, calendar: calendar) }.map(\.item.task) == ["A", "B"])

        filter = TaskFilter(owner: .unassigned, due: .overdue)
        #expect([anna, annaDone, nobody].filter { filter.matches($0, now: recordedAt, calendar: calendar) }.map(\.item.task) == ["C"])
        #expect(filter.isActive)
        #expect(!TaskFilter().isActive)
    }

    @Test("The board collects tasks of all summaries and ticks them off in the note")
    func board() throws {
        let services = try ServiceContainer(
            settings: makeIsolatedSettings(),
            locations: try StorageLocations.temporary(),
            inMemory: true,
            recordingActivity: nil
        )
        let store = services.store
        let resolver = DueDateResolver(calendar: calendar)
        let meeting = Note(title: "Weekly", isTitleUserDefined: true, createdAt: recordedAt, kind: .recording, status: .ready)
        meeting.setSummary(NoteSummary(
            overview: "Planung",
            actionItems: [
                ActionItem(task: "Präsentation erstellen", owner: "Anna", due: "Freitag"),
                ActionItem(task: "Budget prüfen", owner: "Ben"),
            ],
            source: .extractive,
            sourceTimes: ["Präsentation erstellen": 42]
        ), dueDates: resolver)
        let older = Note(title: "Review", isTitleUserDefined: true, createdAt: recordedAt.addingTimeInterval(-86_400), kind: .document, status: .ready)
        older.setSummary(
            NoteSummary(overview: "Rückblick", actionItems: [ActionItem(task: "Doku schreiben", owner: "Anna", due: "heute")], source: .extractive),
            dueDates: resolver
        )
        let withoutSummary = Note(title: "Leer", isTitleUserDefined: true, kind: .document, status: .ready)
        try store.insert(meeting)
        try store.insert(older)
        try store.insert(withoutSummary)

        let board = services.tasks
        board.refresh()
        #expect(board.entries.count == 3)
        #expect(board.openCount == 3)
        // Earliest due date first, tasks without a date last.
        #expect(board.entries.map(\.item.task) == ["Doku schreiben", "Präsentation erstellen", "Budget prüfen"])
        #expect(board.entries[1].dueDate == day(2026, 10, 2))
        #expect(board.entries[1].sourceTime == 42)
        #expect(board.owners.map(\.name) == ["Anna", "Ben"])
        #expect(board.owners.first?.openCount == 2)

        let revision = meeting.contentRevision
        board.setDone(board.entries[1], true)
        #expect(board.openCount == 2)
        #expect(meeting.summary?.actionItems.first?.isDone == true)
        #expect(meeting.contentRevision == revision)

        // A fresh board reads the stored state.
        let reloaded = TaskBoard(store: store, library: services.library)
        reloaded.refresh()
        #expect(reloaded.openCount == 2)
    }
}
