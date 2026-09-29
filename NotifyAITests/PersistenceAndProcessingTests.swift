//
//  PersistenceAndProcessingTests.swift
//  NotifyAITests
//

import Foundation
import Testing
@testable import NotifyAI

@Suite("Note store")
@MainActor
struct NoteStoreTests {
    private let store: NoteStore

    init() throws {
        store = try NoteStore(locations: try StorageLocations.temporary(), inMemory: true)
    }

    @Test("Notes are inserted and found by identifier")
    func insertAndFetch() throws {
        let note = Note(title: "Test", isTitleUserDefined: true, kind: .recording, status: .queued)
        try store.insert(note)
        #expect(store.note(id: note.id)?.title == "Test")
        #expect(store.notes(withStatus: [.queued]).count == 1)
        #expect(store.notes(withStatus: [.ready]).isEmpty)
    }

    @Test("Deleting a note removes its audio file")
    func deleteRemovesAudio() throws {
        let note = Note(title: "Audio", isTitleUserDefined: true, kind: .recording, status: .ready)
        let fileName = NoteStore.recordingFileName(for: note.id)
        note.audioFileName = fileName
        let url = store.locations.audioURL(fileName: fileName)
        try Data([1, 2, 3]).write(to: url)
        try store.insert(note)

        try store.delete(note)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        #expect(store.note(id: note.id) == nil)
    }

    @Test("Markers and summary survive encoding")
    func typedAccessors() throws {
        let note = Note(title: "Accessors", isTitleUserDefined: true, kind: .recording, status: .ready)
        note.markers = [Marker(time: 20), Marker(time: 5)]
        note.summary = NoteSummary(overview: "Kurz gesagt", source: .extractive)
        try store.insert(note)

        let loaded = try #require(store.note(id: note.id))
        #expect(loaded.markers.map(\.time) == [5, 20])
        #expect(loaded.summary?.overview == "Kurz gesagt")
        #expect(loaded.summaryOverview == "Kurz gesagt")
    }
}

@Suite("Processing pipeline")
@MainActor
struct ProcessingCoordinatorTests {
    private let store: NoteStore
    private let settings = makeIsolatedSettings()

    init() throws {
        store = try NoteStore(locations: try StorageLocations.temporary(), inMemory: true)
    }

    private func makeCoordinator(
        transcription: MockTranscriptionEngine = MockTranscriptionEngine(kind: .appleSpeech),
        summarizer: MockSummarizer = MockSummarizer()
    ) -> ProcessingCoordinator {
        ProcessingCoordinator(
            store: store,
            settings: settings,
            transcription: TranscriptionService(appleSpeech: transcription, whisper: transcription),
            summarization: SummarizationService(languageModel: summarizer, fallback: summarizer, availability: { _ in .available }),
            diarizer: SpeakerDiarizer()
        )
    }

    private func makeAudioNote() throws -> Note {
        let note = Note(title: "Aufnahme", isTitleUserDefined: false, kind: .recording, status: .queued)
        let fileName = NoteStore.recordingFileName(for: note.id)
        note.audioFileName = fileName
        try Data([0]).write(to: store.locations.audioURL(fileName: fileName))
        try store.insert(note)
        return note
    }

    private func waitUntilIdle(_ coordinator: ProcessingCoordinator, noteID: UUID) async throws {
        for _ in 0..<200 {
            if let note = store.note(id: noteID), note.status == .ready || note.status == .failed { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Processing did not finish in time")
    }

    @Test("A recording is transcribed, summarized and titled")
    func processesRecording() async throws {
        let coordinator = makeCoordinator()
        let note = try makeAudioNote()

        coordinator.enqueue(.process(note.id))
        try await waitUntilIdle(coordinator, noteID: note.id)

        #expect(note.status == .ready)
        #expect(note.bodyText == "Hallo zusammen.")
        #expect(note.decodedTranscript().count == 1)
        #expect(note.summary?.overview == "Überblick")
        // Recordings are titled with keywords and the recording date.
        #expect(note.title == AutomaticTitle.make(keywords: ["Projekt-Update"], date: note.createdAt))
    }

    @Test("A user-defined title is never replaced")
    func keepsUserTitle() async throws {
        let coordinator = makeCoordinator()
        let note = try makeAudioNote()
        note.title = "Mein Titel"
        note.isTitleUserDefined = true

        coordinator.enqueue(.process(note.id))
        try await waitUntilIdle(coordinator, noteID: note.id)
        #expect(note.title == "Mein Titel")
    }

    @Test("An existing live transcript is not transcribed again")
    func skipsExistingTranscript() async throws {
        let failingEngine = MockTranscriptionEngine(kind: .appleSpeech, error: TestError())
        let coordinator = makeCoordinator(transcription: failingEngine)
        let note = try makeAudioNote()
        let live = [TranscriptSegment(start: 0, end: 1, text: "Live erkannt.")]
        note.setTranscript(encoded: try Transcript.encode(live), plainText: "Live erkannt.", engine: .appleSpeech)

        coordinator.enqueue(.process(note.id))
        try await waitUntilIdle(coordinator, noteID: note.id)
        #expect(note.status == .ready)
        #expect(note.bodyText == "Live erkannt.")
    }

    @Test("Transcription errors mark the note as failed with a message")
    func failure() async throws {
        let coordinator = makeCoordinator(transcription: MockTranscriptionEngine(kind: .appleSpeech, error: TestError()))
        let note = try makeAudioNote()

        coordinator.enqueue(.process(note.id))
        try await waitUntilIdle(coordinator, noteID: note.id)
        #expect(note.status == .failed)
        #expect(note.statusMessage == "Testfehler")
    }

    @Test("Silence is reported instead of producing an empty summary")
    func noSpeech() async throws {
        let coordinator = makeCoordinator(transcription: MockTranscriptionEngine(kind: .appleSpeech, segments: []))
        let note = try makeAudioNote()

        coordinator.enqueue(.process(note.id))
        try await waitUntilIdle(coordinator, noteID: note.id)
        #expect(note.status == .failed)
        #expect(note.statusMessage == ProcessingError.noSpeechDetected.errorDescription)
    }

    @Test("Imported documents are summarized without transcription")
    func processesDocument() async throws {
        let coordinator = makeCoordinator(transcription: MockTranscriptionEngine(kind: .appleSpeech, error: TestError()))
        let note = Note(title: "PDF", isTitleUserDefined: false, kind: .document, status: .queued, bodyText: "Inhalt des Dokuments.")
        try store.insert(note)

        coordinator.enqueue(.process(note.id))
        try await waitUntilIdle(coordinator, noteID: note.id)
        #expect(note.status == .ready)
        #expect(note.summary != nil)
    }

    @Test("Work interrupted by a termination is resumed")
    func resumesInterruptedWork() async throws {
        let coordinator = makeCoordinator()
        let note = try makeAudioNote()
        note.status = .transcribing
        try store.save()

        coordinator.resumePendingWork()
        try await waitUntilIdle(coordinator, noteID: note.id)
        #expect(note.status == .ready)
    }

    @Test("Queued jobs wait while a recording is running")
    func pausesWhileRecording() async throws {
        let coordinator = makeCoordinator()
        let note = try makeAudioNote()
        coordinator.isPaused = true
        coordinator.enqueue(.process(note.id))

        try await Task.sleep(for: .milliseconds(150))
        #expect(note.status == .queued)

        coordinator.isPaused = false
        try await waitUntilIdle(coordinator, noteID: note.id)
        #expect(note.status == .ready)
    }
}
