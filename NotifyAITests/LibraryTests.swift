//
//  LibraryTests.swift
//  NotifyAITests
//
//  The write path of the app: `NoteLibrary` changes notes, the store reports every change
//  as an event, and the services that follow the store (search index, processing) react.
//

import Foundation
import NotifyAICore
@testable import NotifyAIPersistence
@testable import NotifyAI
@testable import NotifyAIServices
import SwiftData
import Testing

@Suite("Note library and store events", .timeLimit(.minutes(1)))
@MainActor
struct LibraryTests {
    private let services: ServiceContainer

    init() throws {
        services = try ServiceContainer(
            settings: makeIsolatedSettings(),
            locations: try StorageLocations.temporary(),
            inMemory: true,
            recordingActivity: nil
        )
    }

    private func insertNote(title: String = "Weekly", summary: NoteSummary? = nil) throws -> Note {
        let note = Note(title: title, isTitleUserDefined: false, kind: .document, status: .ready, bodyText: "Text über das Budget.")
        note.summary = summary
        try services.store.insert(note)
        return note
    }

    @Test("Every change through the library is saved and reported")
    func changesAreReported() async throws {
        let note = try insertNote()
        var saved: [Set<UUID>] = []
        let subscription = services.store.events.subscribe { event in
            if case .saved(let ids) = event { saved.append(ids) }
        }
        defer { subscription.cancel() }

        services.library.setFavorite(true, for: note)
        #expect(services.library.rename(note, to: "  Budget  "))
        #expect(!services.library.rename(note, to: "   "))
        services.library.addMarker(Marker(time: 5), to: note)

        #expect(saved == [[note.id], [note.id], [note.id]])
        #expect(note.isFavorite)
        #expect(note.title == "Budget")
        #expect(note.isTitleUserDefined)
        #expect(note.markers.map(\.time) == [5])
        #expect(!services.store.context.hasChanges)
    }

    @Test("Ticking off a task changes only its row and keeps the search index")
    func taskRow() throws {
        let note = try insertNote(summary: NoteSummary(overview: "Planung", actionItems: [ActionItem(task: "Folien bauen")], source: .extractive))
        let revision = note.contentRevision
        let task = try #require(note.summary?.actionItems.first)

        #expect(services.library.setTask(task.id, isDone: true))
        #expect(note.summary?.actionItems.first?.isDone == true)
        #expect(note.contentRevision == revision)
        #expect(!services.library.setTask(UUID(), isDone: true))
    }

    @Test("Setting the summary again keeps tasks that remain and their state")
    func taskRowsAreReconciled() throws {
        let kept = ActionItem(task: "Folien bauen", owner: "Anna")
        let dropped = ActionItem(task: "Raum buchen")
        let note = try insertNote(summary: NoteSummary(overview: "A", actionItems: [kept, dropped], source: .extractive))
        services.library.setTask(kept.id, isDone: true)

        var summary = try #require(note.summary)
        summary.overview = "B"
        summary.actionItems = [try #require(summary.actionItems.first), ActionItem(task: "Protokoll schicken")]
        note.summary = summary
        try services.store.save()

        #expect(note.summary?.actionItems.map(\.task) == ["Folien bauen", "Protokoll schicken"])
        #expect(note.summary?.actionItems.first?.isDone == true)
        #expect(try services.store.context.fetchCount(FetchDescriptor<NoteTask>()) == 2)
    }

    @Test("The summary is decoded once while its data is unchanged")
    func decodingCache() throws {
        let note = try insertNote(summary: NoteSummary(overview: "Planung", source: .extractive))
        let data = try #require(note.summaryData)
        #expect(note.decodingCache.summary(for: data)?.overview == "Planung")
        // Reading again returns the cached value; new data is decoded again.
        #expect(note.summary?.overview == "Planung")
        note.summary = NoteSummary(overview: "Neu", source: .extractive)
        #expect(note.summary?.overview == "Neu")
    }

    @Test("Deleting a note reaches the search index and the processing")
    func deletionIsFollowed() async throws {
        let note = try insertNote(summary: NoteSummary(overview: "Planung", source: .extractive))
        await services.knowledge.refreshAndWait()
        #expect(services.knowledge.index.notes[note.id] != nil)
        services.processing.enqueue(.resummarize(note.id))

        let id = note.id
        let event = await nextEvent(of: services.store.events) {
            services.library.delete(note)
        }
        guard case .deleted(let ids) = event else {
            Issue.record("Expected a deletion, got \(event)")
            return
        }
        #expect(ids == [id])
        #expect(services.knowledge.index.notes[id] == nil)
        #expect(services.processing.activities[id] == nil)
    }

    @Test("A failed write and an automatic stop become notices for the user")
    func failuresBecomeNotices() throws {
        let notices = UserNotices(store: services.store, recording: services.recording)
        services.store.events.send(.saveFailed(TestError()))
        #expect(notices.current?.title == "Nicht gespeichert")
        #expect(notices.current?.message.contains("Testfehler") == true)

        let noteID = UUID()
        services.recording.events.send(.stoppedAutomatically(noteID: noteID, reason: .writeFailed("Datenträger voll")))
        #expect(notices.pending.last?.noteID == noteID)
        #expect(notices.pending.last?.message.contains("Datenträger voll") == true)
    }

    @Test("Deleting everything stops all work")
    func deleteAll() throws {
        let note = try insertNote()
        services.processing.enqueue(.resummarize(note.id))
        try services.library.deleteAll()
        #expect(services.store.fetch(FetchDescriptor<Note>()).isEmpty)
        #expect(!services.processing.hasPendingWork)
    }
}
