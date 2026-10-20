//
//  NoteEditingTests.swift
//  NotifyAITests
//
//  What the user changes after a recording: deleting only the audio or the transcript, tasks
//  of their own that survive summarizing again, corrections across the whole transcript, the
//  default template, and the schema migration that makes room for it.
//

import Foundation
@testable import NotifyAI
@testable import NotifyAIAudio
@testable import NotifyAICore
@testable import NotifyAIExport
@testable import NotifyAIIntegrations
@testable import NotifyAIKnowledge
@testable import NotifyAILibrary
@testable import NotifyAINeuralModels
@testable import NotifyAIPersistence
@testable import NotifyAIProcessing
@testable import NotifyAIRecording
@testable import NotifyAIServices
@testable import NotifyAISettings
@testable import NotifyAISpeakers
@testable import NotifyAISummarization
@testable import NotifyAISupport
@testable import NotifyAITranscription
import SwiftData
import Testing

@MainActor
private func makeServices(settings: AppSettings = makeIsolatedSettings()) throws -> ServiceContainer {
    try ServiceContainer(settings: settings, locations: try StorageLocations.temporary(), inMemory: true, recordingActivity: nil)
}

private func segment(_ start: Double, _ text: String, speaker: String? = nil) -> TranscriptSegment {
    let words = text.split(separator: " ").enumerated().map { index, word in
        TranscriptWord(text: (index == 0 ? "" : " ") + word, start: start + Double(index) * 0.4, end: start + Double(index) * 0.4 + 0.3)
    }
    return TranscriptSegment(start: start, end: start + Double(words.count) * 0.4, text: text, speaker: speaker, words: words)
}

/// A finished recording with an audio file, a transcript, a summary with tasks and a speaker.
@MainActor
private func insertRecording(
    in services: ServiceContainer,
    createdAt: Date = .now,
    isFavorite: Bool = false,
    segments: [TranscriptSegment] = [segment(0, "Ich schicke das Angebot an Frau Berger.", speaker: "Ich")]
) throws -> Note {
    let note = Note(title: "Weekly", isTitleUserDefined: true, createdAt: createdAt, kind: .recording, status: .ready)
    note.audioFileName = "\(note.id.uuidString).caf"
    let audioURL = services.store.locations.audioURL(fileName: try #require(note.audioFileName))
    try Data(repeating: 7, count: 64_000).write(to: audioURL)
    note.setTranscript(encoded: try Transcript.encode(segments), plainText: Transcript.plainText(of: segments), engine: .whisper)
    note.speakers = [NoteSpeaker(label: "Ich", origin: .named)]
    note.summary = NoteSummary(overview: "Angebot", actionItems: [ActionItem(task: "Angebot an Frau Berger schicken", owner: "Ich")], source: .extractive)
    note.isFavorite = isFavorite
    try services.store.insert(note)
    return note
}

private func fileExists(_ url: URL?) -> Bool {
    url.map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false
}

// MARK: - Deleting parts of a note

@Suite("Deleting the audio or the transcript")
@MainActor
struct PartialDeletionTests {
    @Test("Deleting only the audio removes the file and keeps transcript, summary, tasks and speakers")
    func audioOnly() async throws {
        let services = try makeServices()
        let note = try insertRecording(in: services)
        let url = try #require(services.library.audioURL(for: note))
        #expect(await services.library.audioSize(of: [note]) > 0)

        #expect(services.library.deleteAudio(of: [note]))

        #expect(!fileExists(url))
        #expect(note.audioFileName == nil && !note.hasAudioFile)
        #expect(note.audioRemovedAt != nil)
        #expect(note.hasTranscript && note.hasText)
        #expect(note.summary?.overview == "Angebot")
        #expect(note.sortedTasks.count == 1)
        #expect(note.speakers.map(\.label) == ["Ich"])
        #expect(!services.library.canDeleteAudio(of: note))
        #expect(!services.store.context.hasChanges)
    }

    @Test("Audio is kept while the note is recorded or processed")
    func audioInUse() throws {
        let services = try makeServices()
        let note = try insertRecording(in: services)
        note.status = .transcribing
        #expect(!services.library.canDeleteAudio(of: note))
        #expect(services.library.deleteAudio(of: [note]))
        #expect(note.hasAudioFile)
        #expect(fileExists(services.library.audioURL(for: note)))
    }

    @Test("Deleting the transcript keeps summary, tasks and audio; the note can be transcribed again")
    func transcriptOnly() throws {
        let services = try makeServices()
        let note = try insertRecording(in: services)
        let revision = note.contentRevision

        #expect(services.library.deleteTranscript(of: note))

        #expect(!note.hasTranscript && !note.hasText)
        #expect(note.speakers.isEmpty)
        #expect(note.summary?.overview == "Angebot")
        #expect(note.sortedTasks.map(\.task) == ["Angebot an Frau Berger schicken"])
        #expect(note.hasAudioFile && fileExists(services.library.audioURL(for: note)))
        // The search index forgets the text.
        #expect(note.contentRevision > revision)
        #expect(!services.library.canDeleteTranscript(of: note))
    }

    @Test("Older recordings by age; automatic deletion spares favorites and newer recordings")
    func retention() throws {
        let settings = makeIsolatedSettings()
        let services = try makeServices(settings: settings)
        let now = Date.now
        let old = try insertRecording(in: services, createdAt: now.addingTimeInterval(-40 * 86_400))
        let oldFavorite = try insertRecording(in: services, createdAt: now.addingTimeInterval(-50 * 86_400), isFavorite: true)
        let recent = try insertRecording(in: services, createdAt: now.addingTimeInterval(-2 * 86_400))

        let cutoff = try #require(AudioRetention.thirtyDays.cutoff(now: now))
        #expect(Set(services.library.notesWithAudio(recordedBefore: cutoff).map(\.id)) == [old.id, oldFavorite.id])
        #expect(services.library.notesWithAudio(recordedBefore: cutoff, includingFavorites: false).map(\.id) == [old.id])
        #expect(services.library.notesWithAudio().count == 3)

        // Keeping everything deletes nothing.
        #expect(services.storage.applyAudioRetention(now: now) == 0)
        settings.storage.audioRetention = .thirtyDays
        #expect(services.storage.applyAudioRetention(now: now) == 1)
        #expect(!old.hasAudioFile && old.hasTranscript)
        #expect(oldFavorite.hasAudioFile)
        #expect(recent.hasAudioFile)
        #expect(AudioRetention.forever.cutoff() == nil)
    }
}

// MARK: - Tasks of the user's own

@Suite("Editing tasks")
@MainActor
struct TaskEditingTests {
    @Test("Tasks can be added, changed and removed; each change reaches the search index")
    func addChangeRemove() throws {
        let services = try makeServices()
        let note = try insertRecording(in: services)
        var revision = note.contentRevision

        #expect(!services.library.addTask(TaskDraft(task: "   "), to: note))
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(services.library.addTask(TaskDraft(task: " Folien bauen ", owner: " Eddy ", dueDate: due), to: note))
        #expect(note.contentRevision > revision)
        let added = try #require(note.sortedTasks.last)
        #expect(note.sortedTasks.map(\.task) == ["Angebot an Frau Berger schicken", "Folien bauen"])
        #expect(added.owner == "Eddy")
        #expect(added.isUserEdited)
        #expect(added.dueDate == Calendar.current.startOfDay(for: due))
        #expect(added.due?.isEmpty == false)
        #expect(note.summary?.actionItems.map(\.task) == ["Angebot an Frau Berger schicken", "Folien bauen"])

        revision = note.contentRevision
        let generated = try #require(note.sortedTasks.first)
        #expect(services.library.updateTask(generated.id, with: TaskDraft(task: "Angebot bis Montag schicken", owner: "", dueDate: nil)))
        #expect(generated.task == "Angebot bis Montag schicken")
        #expect(generated.owner == nil)
        #expect(generated.isUserEdited)
        #expect(note.contentRevision > revision)

        #expect(services.library.deleteTask(added.id))
        #expect(note.sortedTasks.map(\.task) == ["Angebot bis Montag schicken"])
        #expect(note.sortedTasks.map(\.position) == [0])
        #expect(!services.store.context.hasChanges)
    }

    @Test("A spoken deadline keeps its words while the day stays; another day is written as a date")
    func spokenDeadline() throws {
        let services = try makeServices()
        let note = try insertRecording(in: services)
        note.summary = NoteSummary(overview: "Angebot", actionItems: [ActionItem(task: "Angebot schicken", due: "Freitag")], source: .extractive)
        let task = try #require(note.sortedTasks.first)
        let friday = try #require(task.dueDate)

        var draft = TaskDraft(task)
        draft.owner = "Anna"
        #expect(services.library.updateTask(task.id, with: draft))
        #expect(task.due == "Freitag")
        #expect(task.dueDate == friday)

        draft.dueDate = friday.addingTimeInterval(3 * 86_400)
        #expect(services.library.updateTask(task.id, with: draft))
        #expect(task.due != "Freitag")
        #expect(task.dueDate == Calendar.current.startOfDay(for: friday.addingTimeInterval(3 * 86_400)))
    }

    @Test("Summarizing again keeps the user's tasks and ticks, replaces the others")
    func summarizingAgain() throws {
        let services = try makeServices()
        let note = try insertRecording(in: services)
        note.summary = NoteSummary(
            overview: "Planung",
            actionItems: [ActionItem(task: "Angebot an Frau Berger schicken"), ActionItem(task: "Budget prüfen"), ActionItem(task: "Raum buchen")],
            source: .extractive
        )
        let offer = try #require(note.sortedTasks.first)
        offer.isDone = true
        let budget = note.sortedTasks[1]
        services.library.updateTask(budget.id, with: TaskDraft(task: "Budget für den Relaunch prüfen", owner: "Ben"))
        services.library.addTask(TaskDraft(task: "Folien bauen"), to: note)

        // The new summary words the offer anew, finds the budget task again and drops the room.
        note.summary = NoteSummary(
            overview: "Planung neu",
            actionItems: [ActionItem(task: "Das Angebot an Frau Berger schicken"), ActionItem(task: "Budget prüfen"), ActionItem(task: "Catering bestellen")],
            source: .appleIntelligence
        )

        let tasks = note.sortedTasks
        #expect(tasks.map(\.task) == ["Das Angebot an Frau Berger schicken", "Budget für den Relaunch prüfen", "Catering bestellen", "Folien bauen"])
        // The same row, still ticked off, under its new wording.
        #expect(tasks[0].id == offer.id && tasks[0].isDone)
        #expect(tasks[1].id == budget.id && tasks[1].owner == "Ben")
        #expect(tasks.map(\.position) == [0, 1, 2, 3])
        #expect(try services.store.context.fetchCount(FetchDescriptor<NoteTask>()) == 4)

        // A new transcript clears the summary; the user's tasks remain.
        note.summary = nil
        #expect(note.sortedTasks.map(\.task) == ["Budget für den Relaunch prüfen", "Folien bauen"])
    }

    @Test("The same task in other words")
    func identity() {
        #expect(TaskIdentity.matches("Angebot an Frau Berger schicken", "Das überarbeitete Angebot an Frau Berger schicken"))
        #expect(TaskIdentity.matches("Budget prüfen", "budget prüfen."))
        #expect(TaskIdentity.matches("Kunden anrufen", "Den Kunden anrufen"))
        #expect(!TaskIdentity.matches("Budget prüfen", "Vertrag prüfen"))
        #expect(!TaskIdentity.matches("Angebot schicken", "Rechnung schicken"))
        #expect(!TaskIdentity.matches("", "Budget prüfen"))
    }

    @Test("Renaming a speaker renames the owner of its tasks")
    func renamingSpeaker() async throws {
        let services = try makeServices()
        let note = try insertRecording(in: services, segments: [segment(0, "Ich prüfe das Budget.", speaker: "Sprecher 2")])
        note.speakers = [NoteSpeaker(label: "Sprecher 2", origin: .detected)]
        note.summary = NoteSummary(overview: "Budget", actionItems: [ActionItem(task: "Budget prüfen", owner: "Sprecher 2")], source: .extractive)
        try services.store.save()

        try await services.speakers.rename("Sprecher 2", to: "Ben", in: note, remembersVoice: false)

        #expect(note.sortedTasks.first?.owner == "Ben")
        #expect(note.decodedTranscript().first?.speaker == "Ben")
    }
}

// MARK: - Corrections across the transcript

@Suite("Correcting transcripts")
@MainActor
struct TranscriptCorrectionTests {
    @Test("A misrecognized name is replaced everywhere, as whole words, with its timing")
    func replaceEverywhere() async throws {
        let services = try makeServices()
        let note = try insertRecording(in: services, segments: [
            segment(0, "Frau Berga schickt das Angebot.", speaker: "Anna"),
            segment(4, "Danke, Frau berga. Bergamo ist kein Thema.", speaker: "Ich"),
        ])
        let editor = services.transcriptEditor
        #expect(editor.occurrences(of: "Berga", in: note) == 2)
        #expect(editor.occurrences(of: "Berga", in: note, matchesCase: true) == 1)
        #expect(editor.occurrences(of: " ", in: note) == 0)

        #expect(try await editor.replace("frau berga", with: "Frau Berger", in: note) == 2)

        let segments = note.decodedTranscript()
        #expect(segments.map(\.text) == ["Frau Berger schickt das Angebot.", "Danke, Frau Berger. Bergamo ist kein Thema."])
        // Unchanged words keep their timing exactly.
        #expect(segments[0].words.last?.start == 0 + 4 * 0.4)
        #expect(note.bodyText.contains("Frau Berger schickt"))
        #expect(note.transcriptEditedAt != nil)
    }

    @Test("Replacing with nothing removes the word; a passage left empty is removed")
    func replaceWithNothing() async throws {
        let services = try makeServices()
        let note = try insertRecording(in: services, segments: [segment(0, "Also das Budget steht."), segment(3, "Also")])
        #expect(try await services.transcriptEditor.replace("also", with: "", in: note) == 2)
        #expect(note.decodedTranscript().map(\.text) == ["das Budget steht."])
    }

    @Test("A passage joins the one before it with its words and keeps the first speaker")
    func merge() async throws {
        let services = try makeServices()
        let note = try insertRecording(in: services, segments: [segment(0, "Wir schicken das", speaker: "Anna"), segment(2, "Angebot morgen.", speaker: "Ben")])
        let second = try #require(note.decodedTranscript().last)
        #expect(try await !services.transcriptEditor.mergeWithPrevious(try #require(note.decodedTranscript().first).id, in: note))
        #expect(try await services.transcriptEditor.mergeWithPrevious(second.id, in: note))
        let segments = note.decodedTranscript()
        #expect(segments.count == 1)
        #expect(segments[0].text == "Wir schicken das Angebot morgen.")
        #expect(segments[0].speaker == "Anna")
        #expect(segments[0].words.map(\.text).joined() == "Wir schicken das Angebot morgen.")
        #expect(segments[0].end == second.end)
    }

    @Test("The text of an imported document can be corrected and searched")
    func documentText() async throws {
        let services = try makeServices()
        let note = Note(title: "Scan", isTitleUserDefined: true, kind: .document, status: .ready, bodyText: "Rechnumg Nr. 12 über 300 Euro.")
        try services.store.insert(note)
        #expect(try await services.transcriptEditor.replace("Rechnumg", with: "Rechnung", in: note) == 1)
        #expect(note.bodyText == "Rechnung Nr. 12 über 300 Euro.")
        try services.transcriptEditor.setText("  Rechnung Nr. 13  ", of: note)
        #expect(note.bodyText == "Rechnung Nr. 13")
        #expect(note.transcriptEditedAt != nil)
        #expect(!services.store.context.hasChanges)
    }
}

// MARK: - Default template

@Suite("Default template")
@MainActor
struct DefaultTemplateTests {
    @Test("The choice is stored and read back; unknown values fall back to Allgemein")
    func storage() throws {
        let id = UUID()
        for choice in [SummaryTemplateChoice.focus(.lecture), .custom(id)] {
            #expect(SummaryTemplateChoice(storageValue: choice.storageValue) == choice)
        }
        #expect(SummaryTemplateChoice(storageValue: "focus.unbekannt") == nil)
        #expect(SummaryTemplateChoice(storageValue: "custom") == nil)

        let suite = "NotifyAITests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AppSettings(defaults: defaults).analysis.defaultTemplate = .focus(.oneOnOne)
        #expect(AppSettings(defaults: defaults).analysis.defaultTemplate == .focus(.oneOnOne))
        defaults.set("kaputt", forKey: "processing.defaultTemplate")
        #expect(AppSettings(defaults: defaults).analysis.defaultTemplate == .focus(.general))
    }

    @Test("New recordings start with the default; deleting that template restores Allgemein")
    func recordingsAndDeletion() throws {
        let settings = makeIsolatedSettings()
        settings.analysis.defaultTemplate = .focus(.meeting)
        let services = try makeServices(settings: settings)
        #expect(services.recording.draft.focus == .meeting)
        #expect(services.recording.draft.templateID == nil)

        let template = try services.templates.create(SummaryTemplates.draft(basedOn: .sales))
        #expect(template.symbolName == RecordingFocus.sales.symbolName)
        #expect(template.instructions == RecordingFocus.sales.summaryDescription)
        #expect(SummaryTemplates.symbols.contains(template.symbolName))
        settings.analysis.defaultTemplate = .custom(template.id)
        #expect(RecordingController.Draft(template: settings.analysis.defaultTemplate).templateID == template.id)

        try services.templates.delete(template)
        #expect(settings.analysis.defaultTemplate == .focus(.general))
    }

    @Test("Every built-in template has a symbol the editor offers and a description")
    func builtIn() {
        for focus in RecordingFocus.allCases {
            #expect(SummaryTemplates.symbols.contains(focus.symbolName), "\(focus)")
            #expect(!focus.summaryDescription.isEmpty)
        }
    }
}

// MARK: - Time display

@Suite("Recording time")
struct RecordingTimeTests {
    @Test("From the first hour on, hours, minutes and seconds")
    func pastAnHour() {
        #expect(TimeFormatting.timestamp(59 * 60 + 59) == "59:59")
        #expect(TimeFormatting.timestamp(3_600) == "1:00:00")
        #expect(TimeFormatting.timestamp(3_600 + 61) == "1:01:01")
        #expect(TimeFormatting.timestamp(10 * 3_600 + 5) == "10:00:05")
    }
}

// MARK: - Migration

@Suite("Schema migration to V6")
@MainActor
struct MigrationToV6Tests {
    @Test("V5 notes and tasks open with V6: no audio removal, no tasks of the user's own")
    func fromV5() throws {
        let locations = try StorageLocations.temporary()
        let noteID = UUID()
        let taskID = UUID()
        do {
            let schema = Schema(versionedSchema: NotifyAISchemaV5.self)
            let configuration = ModelConfiguration(schema: schema, url: locations.databaseURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: configuration)
            let context = ModelContext(container)
            let note = NotifyAISchemaV5.Note(id: noteID, title: "Weekly", isTitleUserDefined: true, kind: .recording, status: .ready, audioFileName: "a.caf")
            context.insert(note)
            let task = NotifyAISchemaV5.NoteTask(
                id: taskID, task: "Budget prüfen", owner: "Ben", due: nil, dueDate: nil, isDone: true, position: 0, sourceTime: 12
            )
            context.insert(task)
            note.tasks = [task]
            try context.save()
        }

        let store = try NoteStore(locations: locations)
        let note = try #require(store.note(id: noteID))
        #expect(note.audioFileName == "a.caf")
        #expect(note.audioRemovedAt == nil)
        let task = try #require(note.sortedTasks.first)
        #expect(task.id == taskID && task.isDone && task.sourceTime == 12)
        #expect(!task.isUserEdited)
    }
}
