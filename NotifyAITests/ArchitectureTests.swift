//
//  ArchitectureTests.swift
//  NotifyAITests
//
//  Tests for the split-up building blocks: index persistence, pipeline steps,
//  recording collaborators and grouped settings.
//

import Foundation
import Testing
@testable import NotifyAI

// MARK: - Index persistence

@Suite("Search index persistence")
@MainActor
struct KnowledgeIndexStoreTests {
    private func makeReadyNote(in store: NoteStore, title: String, text: String) throws -> Note {
        let note = Note(title: title, isTitleUserDefined: true, kind: .document, status: .ready, bodyText: text)
        try store.insert(note)
        return note
    }

    private func modificationDate(of url: URL) throws -> Date {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.modificationDate] as? Date)
    }

    @Test("Only the files of changed notes are written")
    func incrementalWrites() async throws {
        let locations = try StorageLocations.temporary()
        let store = try NoteStore(locations: locations, inMemory: true)
        let first = try makeReadyNote(in: store, title: "Budget", text: "Das Budget der Kampagne liegt bei 12.000 Euro.")
        let second = try makeReadyNote(in: store, title: "Statistik", text: "Die Varianz beschreibt die Streuung.")
        let directory = locations.knowledgeIndexDirectory
        let service = KnowledgeIndexService(store: store, embedder: SentenceEmbedder(), persistence: KnowledgeIndexStore(directory: directory))

        await service.refreshAndWait()
        let firstFile = directory.appending(path: "\(first.id.uuidString).plist")
        let secondFile = directory.appending(path: "\(second.id.uuidString).plist")
        let untouchedDate = try modificationDate(of: secondFile)
        let firstDate = try modificationDate(of: firstFile)

        try await Task.sleep(for: .milliseconds(1_100))
        first.title = "Budget 2027"
        try store.save()
        await service.refreshAndWait()

        #expect(try modificationDate(of: firstFile) > firstDate)
        #expect(try modificationDate(of: secondFile) == untouchedDate)
        #expect(service.index.notes[first.id]?.title == "Budget 2027")
    }

    @Test("A stored index is loaded again, deleted notes are removed from disk")
    func loadAndRemove() async throws {
        let locations = try StorageLocations.temporary()
        let store = try NoteStore(locations: locations, inMemory: true)
        let kept = try makeReadyNote(in: store, title: "Bleibt", text: "Ein Text über die Herbstkampagne.")
        let deleted = try makeReadyNote(in: store, title: "Weg", text: "Ein Text über die Datenbank.")
        let persistence = KnowledgeIndexStore(directory: locations.knowledgeIndexDirectory)
        let service = KnowledgeIndexService(store: store, embedder: SentenceEmbedder(), persistence: persistence)
        await service.refreshAndWait()

        service.remove([deleted.id])
        try await Task.sleep(for: .milliseconds(100))
        let reloaded = await KnowledgeIndexStore(directory: locations.knowledgeIndexDirectory).load()
        #expect(Set(reloaded.notes.keys) == [kept.id])
    }

    @Test("An index in an older format is discarded, the legacy file removed")
    func outdatedFormat() async throws {
        let locations = try StorageLocations.temporary()
        try Data("alt".utf8).write(to: locations.legacyKnowledgeIndexURL)
        let persistence = KnowledgeIndexStore(directory: locations.knowledgeIndexDirectory, legacyFile: locations.legacyKnowledgeIndexURL)
        let index = await persistence.load()
        #expect(index.notes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: locations.legacyKnowledgeIndexURL.path(percentEncoded: false)))
    }

    @Test("Unchanged notes are not indexed again")
    func fingerprintSkipsUnchanged() async throws {
        let store = try NoteStore(locations: try StorageLocations.temporary(), inMemory: true)
        let note = try makeReadyNote(in: store, title: "A", text: "Text")
        let service = KnowledgeIndexService(store: store, embedder: SentenceEmbedder(), persistence: nil)
        await service.refreshAndWait()
        let revision = service.revision
        await service.refreshAndWait()
        #expect(service.revision == revision)

        note.isFavorite = true
        try store.save()
        await service.refreshAndWait()
        #expect(service.revision == revision + 1)
    }
}

// MARK: - Pipeline

@Suite("Processing pipeline steps")
@MainActor
struct PipelineStepTests {
    private let settings = makeIsolatedSettings()

    private func note(kind: NoteKind, transcript: Bool, summary: Bool) throws -> Note {
        let note = Note(title: "N", isTitleUserDefined: true, kind: kind, status: .queued)
        if transcript {
            let segments = [TranscriptSegment(start: 0, end: 1, text: "Hallo.")]
            note.setTranscript(encoded: try Transcript.encode(segments), plainText: "Hallo.", engine: .appleSpeech)
        }
        if summary {
            note.summary = NoteSummary(overview: "Kurz", source: .extractive)
        }
        return note
    }

    @Test("Each step runs only when its result is missing or forced")
    func stepSelection() throws {
        let engine = MockTranscriptionEngine(kind: .appleSpeech)
        let transcription = TranscriptionStep(transcription: TranscriptionService(appleSpeech: engine, whisper: engine), settings: settings.transcription)
        let speakers = SpeakerStep(settings: settings.analysis, diarizer: SpeakerDiarizer())
        let summary = SummaryStep(summarization: SummarizationService(), digestStore: ChapterDigestStore(directory: nil), embedder: SentenceEmbedder())

        let fresh = try note(kind: .recording, transcript: false, summary: false)
        #expect(transcription.needsToRun(for: fresh, options: ProcessingOptions()))
        #expect(summary.needsToRun(for: fresh, options: ProcessingOptions()))

        let done = try note(kind: .recording, transcript: true, summary: true)
        #expect(!transcription.needsToRun(for: done, options: ProcessingOptions()))
        #expect(!speakers.needsToRun(for: done, options: ProcessingOptions()))
        #expect(!summary.needsToRun(for: done, options: ProcessingOptions()))
        #expect(transcription.needsToRun(for: done, options: ProcessingOptions(forceTranscription: true)))
        #expect(summary.needsToRun(for: done, options: ProcessingOptions(forceSummary: true)))

        let document = try note(kind: .document, transcript: false, summary: false)
        #expect(!transcription.needsToRun(for: document, options: ProcessingOptions(forceTranscription: true)))
        #expect(!speakers.needsToRun(for: document, options: ProcessingOptions()))
    }

    @Test("Jobs map to the right options")
    func jobOptions() {
        let id = UUID()
        #expect(ProcessingCoordinator.Job.process(id).options == ProcessingOptions())
        #expect(ProcessingCoordinator.Job.retranscribe(id).options == ProcessingOptions(forceTranscription: true, forceSummary: true))
        #expect(ProcessingCoordinator.Job.resummarize(id).options == ProcessingOptions(forceSummary: true))
    }
}

// MARK: - Recording collaborators

@Suite("Recording building blocks")
@MainActor
struct RecordingPartsTests {
    @Test("The meter keeps a fixed-length level history")
    func meter() {
        let meter = RecordingMeter()
        meter.record(AudioLevel(rms: 0.3, systemRMS: 0.1, recordedTime: 1.5, hasReceivedSystemAudio: true))
        #expect(meter.elapsed == 1.5)
        #expect(meter.levels.count == RecordingMeter.historyLength)
        #expect(meter.levels.last == RecordingMeter.meterValue(0.3))
        #expect(meter.systemLevels.last == RecordingMeter.meterValue(0.1))
        #expect(meter.hasReceivedSystemAudio)
        meter.reset()
        #expect(meter.elapsed == 0)
        #expect(!meter.hasReceivedSystemAudio)
    }

    @Test("A live transcript whose engine cannot start reports why")
    func unavailableLiveTranscript() async throws {
        let feed = LiveTranscriptFeed()
        feed.start(engine: MockTranscriptionEngine(kind: .appleSpeech), kind: .appleSpeech, options: TranscriptionOptions(language: .german, whisperModel: .recommended))
        #expect(feed.state == .preparing)
        for _ in 0..<50 where feed.state == .preparing {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .unavailable = feed.state else {
            Issue.record("Expected an unavailable live transcript, got \(feed.state)")
            return
        }
        #expect(await feed.finish().isEmpty)
    }

    @Test("A new recording note carries title, participants and source")
    func noteWriter() throws {
        let store = try NoteStore(locations: try StorageLocations.temporary(), inMemory: true)
        var draft = RecordingController.Draft()
        draft.title = "  Weekly  "
        draft.participants = "Anna, , Ben"
        let note = RecordingNoteWriter(store: store).makeNote(
            draft: draft,
            configuration: CaptureConfiguration(source: .microphoneAndSystemAudio, systemAudioTarget: .app(bundleID: "us.zoom.xos", name: "Zoom")),
            language: .german
        )
        #expect(note.title == "Weekly")
        #expect(note.isTitleUserDefined)
        #expect(note.participants == ["Anna", "Ben"])
        #expect(note.audioSource == .microphoneAndSystemAudio)
        #expect(note.sourceAppName == "Zoom")
        #expect(note.audioFileName == NoteStore.recordingFileName(for: note.id))
    }
}

// MARK: - Settings groups

@Suite("Grouped settings")
@MainActor
struct GroupedSettingsTests {
    @Test("Groups keep the stored keys, so existing preferences survive the split")
    func existingKeys() throws {
        let suiteName = "NotifyAITests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // Values as the single settings object stored them before.
        defaults.set("whisper", forKey: "transcription.engine")
        defaults.set(true, forKey: "privacy.appLock")
        defaults.set("menuBar", forKey: "app.presence")
        defaults.set(false, forKey: "processing.speakersFromAudioSource")

        let settings = AppSettings(defaults: defaults)
        #expect(settings.transcription.engine == .whisper)
        #expect(settings.privacy.appLockEnabled)
        #expect(settings.general.appPresence == .menuBar)
        #expect(!settings.analysis.speakersFromAudioSource)
    }
}
