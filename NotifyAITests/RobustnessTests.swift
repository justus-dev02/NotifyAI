//
//  RobustnessTests.swift
//  NotifyAITests
//
//  Live transcription backlog, schema migrations on real store files, database recovery,
//  failure notices and the energy-related building blocks.
//

@testable import AudioCapture
import Foundation
@testable import NotifyAI
import NotifyAICore
import SwiftData
import Synchronization
import Testing

// MARK: - Live transcription backlog

/// A live session that reports a fixed backlog for every appended chunk.
private actor BackloggedSession: LiveTranscriptionSession {
    nonisolated let events: AsyncStream<LiveTranscriptionEvent>
    private let continuation: AsyncStream<LiveTranscriptionEvent>.Continuation
    private let reportedBacklog: TimeInterval
    private(set) var isCancelled = false

    init(reportedBacklog: TimeInterval) {
        (events, continuation) = AsyncStream.makeStream(of: LiveTranscriptionEvent.self)
        self.reportedBacklog = reportedBacklog
    }

    func append(_ chunk: AudioChunk) {
        continuation.yield(.backlog(reportedBacklog))
    }

    func finish() async throws -> [TranscriptSegment] {
        continuation.finish()
        return []
    }

    func cancel() {
        isCancelled = true
        continuation.finish()
    }
}

private struct SessionEngine: TranscriptionEngine {
    let kind = TranscriptionEngineKind.whisper
    let session: BackloggedSession?
    /// How long "loading the model" takes.
    var loadingTime: Duration = .zero

    func startLiveSession(options: TranscriptionOptions) async throws -> any LiveTranscriptionSession {
        try await Task.sleep(for: loadingTime)
        return session ?? BackloggedSession(reportedBacklog: 0)
    }

    func transcribeFile(at url: URL, options: TranscriptionOptions, progress: @escaping @Sendable (Double) -> Void) async throws -> [TranscriptSegment] {
        []
    }
}

@Suite("Live transcription backlog")
@MainActor
struct LiveTranscriptBacklogTests {
    private let options = TranscriptionOptions(language: .german, whisperModel: .recommended)

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Audio buffered while the model loads is limited")
    func bufferedWhileLoading() async throws {
        let feed = LiveTranscriptFeed(maximumBacklog: 1)
        var fellBehind = 0
        feed.onFellBehind = { fellBehind += 1 }
        feed.start(engine: SessionEngine(session: nil, loadingTime: .seconds(30)), kind: .whisper, options: options)
        for chunk in Signal.chunks(of: Signal.silence(seconds: 1.5), size: 1_600) {
            await feed.append(chunk)
        }
        #expect(feed.state == .fellBehind)
        #expect(fellBehind == 1)
        #expect(feed.backlog == 0)
        // The file is transcribed after the recording instead.
        #expect(await feed.finish().isEmpty)
    }

    @Test("A session that falls behind is abandoned")
    func sessionBacklog() async throws {
        let session = BackloggedSession(reportedBacklog: 90)
        let feed = LiveTranscriptFeed(maximumBacklog: 60)
        feed.start(engine: SessionEngine(session: session), kind: .whisper, options: options)
        try await waitUntil { feed.state == .running }
        await feed.append(AudioChunk(samples: Signal.silence(seconds: 0.1), startFrame: 0))
        try await waitUntil { feed.state == .fellBehind }
        #expect(feed.state == .fellBehind)
        for _ in 0..<100 where !(await session.isCancelled) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await session.isCancelled)
    }

    @Test("A session within the limit keeps running")
    func withinLimit() async throws {
        let feed = LiveTranscriptFeed(maximumBacklog: 60)
        feed.start(engine: SessionEngine(session: BackloggedSession(reportedBacklog: 5)), kind: .whisper, options: options)
        try await waitUntil { feed.state == .running }
        await feed.append(AudioChunk(samples: Signal.silence(seconds: 0.1), startFrame: 0))
        try await Task.sleep(for: .milliseconds(50))
        #expect(feed.state == .running)
        #expect(feed.backlog == 5)
    }
}

// MARK: - Migrations

@Suite("Schema migrations on real store files")
@MainActor
struct MigrationTests {
    @Test("V1 → V3: text moves into its own entity, everything else is kept")
    func fromV1() throws {
        let locations = try StorageLocations.temporary()
        let id = UUID()
        do {
            let schema = Schema(versionedSchema: NotifyAISchemaV1.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: locations.databaseURL, cloudKitDatabase: .none))
            let context = ModelContext(container)
            let note = NotifyAISchemaV1.Note(id: id, title: "Budget", isTitleUserDefined: true, kind: .recording, status: .ready,
                                             participants: ["Anna"], bodyText: "Das Budget liegt bei 12.000 Euro.")
            note.summaryOverview = "Budgetplanung"
            context.insert(note)
            try context.save()
        }

        let store = try NoteStore(locations: locations)
        let note = try #require(store.note(id: id))
        #expect(note.title == "Budget")
        #expect(note.participants == ["Anna"])
        #expect(note.bodyText == "Das Budget liegt bei 12.000 Euro.")
        #expect(note.textLength == note.bodyText.count)
        #expect(note.legacyBodyText.isEmpty)
        #expect(note.contentRevision == 1)
        #expect(note.audioSource == .microphone)
    }

    @Test("V2 → V3 keeps the audio source and makes the text searchable through the relationship")
    func fromV2() throws {
        let locations = try StorageLocations.temporary()
        do {
            let schema = Schema(versionedSchema: NotifyAISchemaV2.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: locations.databaseURL, cloudKitDatabase: .none))
            let context = ModelContext(container)
            for index in 0..<120 {
                let note = NotifyAISchemaV2.Note(title: "Meeting \(index)", isTitleUserDefined: true, kind: .recording, status: .ready,
                                                 bodyText: index == 77 ? "Wir besprechen die Herbstkampagne." : "Allgemeines Gespräch \(index).")
                note.audioSourceRawValue = RecordingAudioSource.microphoneAndSystemAudio.rawValue
                context.insert(note)
            }
            let empty = NotifyAISchemaV2.Note(title: "Leer", isTitleUserDefined: true, kind: .recording, status: .failed)
            context.insert(empty)
            try context.save()
        }

        let store = try NoteStore(locations: locations)
        let all = try store.context.fetch(FetchDescriptor<Note>())
        #expect(all.count == 121)
        #expect(all.allSatisfy { $0.legacyBodyText.isEmpty })
        #expect(all.filter { $0.content != nil }.count == 120)
        #expect(all.first { $0.title == "Leer" }?.hasText == false)
        #expect(all.allSatisfy { $0.audioSource == .microphoneAndSystemAudio || $0.title == "Leer" })

        let matches = try store.context.fetch(FetchDescriptor(predicate: NoteQueries.library(filter: .all, searchText: "herbstkampagne")))
        #expect(matches.map(\.title) == ["Meeting 77"])
    }
}

// MARK: - Content revisions

@Suite("Content revision and index fingerprint")
@MainActor
struct ContentRevisionTests {
    @Test("Text, transcript and summary changes count as content changes; ticking off a task does not")
    func revisions() throws {
        let store = try NoteStore(locations: try StorageLocations.temporary(), inMemory: true)
        let note = Note(title: "N", isTitleUserDefined: true, kind: .document, status: .ready, bodyText: "Text")
        try store.insert(note)
        #expect(note.hasText)
        let initial = note.contentRevision

        note.summary = NoteSummary(overview: "Kurz", actionItems: [ActionItem(task: "Folien bauen")], source: .extractive)
        #expect(note.contentRevision == initial + 1)
        let fingerprint = IndexableNote.fingerprint(of: note)

        let item = try #require(note.summary?.actionItems.first)
        #expect(note.setActionItem(item.id, isDone: true))
        #expect(note.summary?.actionItems.first?.isDone == true)
        #expect(note.contentRevision == initial + 1)
        #expect(IndexableNote.fingerprint(of: note) == fingerprint)

        note.bodyText = "Neuer Text"
        #expect(note.contentRevision == initial + 2)
        #expect(note.textLength == 10)
        #expect(IndexableNote.fingerprint(of: note) != fingerprint)

        note.isFavorite = true
        #expect(IndexableNote.fingerprint(of: note) != fingerprint)
    }

    @Test("Deleting a note deletes its text")
    func cascade() throws {
        let store = try NoteStore(locations: try StorageLocations.temporary(), inMemory: true)
        let note = Note(title: "N", isTitleUserDefined: true, kind: .document, status: .ready, bodyText: "Text")
        try store.insert(note)
        #expect(try store.context.fetchCount(FetchDescriptor<NoteContent>()) == 1)
        try store.delete(note)
        #expect(try store.context.fetchCount(FetchDescriptor<NoteContent>()) == 0)
    }
}

// MARK: - Recovery

@Suite("Database recovery")
@MainActor
struct DatabaseRecoveryTests {
    private struct BrokenDatabase: LocalizedError {
        var errorDescription: String? { "Die Datenbank ist beschädigt." }
    }

    @Test("A database that cannot be opened leads to the recovery screen, not a crash")
    func failureIsReported() {
        let launch = AppLaunch(makeEnvironment: { throw BrokenDatabase() }, makeLocations: { try StorageLocations.temporary() })
        #expect(launch.environment == nil)
        #expect(launch.failure == "Die Datenbank ist beschädigt.")
    }

    @Test("Resetting moves the database aside and restores the recordings as notes")
    func reset() async throws {
        let locations = try StorageLocations.temporary()
        try Data("kaputt".utf8).write(to: locations.databaseURL)
        let recordingID = UUID()
        try Data().write(to: locations.audioURL(fileName: NoteStore.recordingFileName(for: recordingID)))
        try Data().write(to: locations.recordingsDirectory.appending(path: "notiz.txt"))

        var attempts = 0
        let launch = AppLaunch(makeEnvironment: {
            attempts += 1
            if attempts == 1 { throw BrokenDatabase() }
            return try AppEnvironment(settings: makeIsolatedSettings(), locations: locations, inMemory: true)
        }, makeLocations: { locations })
        #expect(launch.environment == nil)

        await launch.resetDatabase()
        let environment = try #require(launch.environment)
        #expect(launch.failure == nil)
        let folder = try #require(launch.movedDatabaseFolder)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "NotifyAI.store").path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: locations.databaseURL.path(percentEncoded: false)))

        let restored = try #require(environment.store.note(id: recordingID))
        #expect(restored.kind == .recording)
        #expect(restored.audioFileName == NoteStore.recordingFileName(for: recordingID))
        // Queued for transcription (processing may already have picked it up).
        #expect(restored.status != .ready && restored.status != .recording)
        // A second run finds nothing new.
        #expect(try await environment.store.recoverOrphanedRecordings().isEmpty)
    }

    @Test("The same failure is shown once")
    func noticesAreDeduplicated() {
        let notices = UserNotices()
        notices.post(UserNotice(title: "Nicht gespeichert", message: "Kein Platz"))
        notices.post(UserNotice(title: "Nicht gespeichert", message: "Kein Platz"))
        notices.post(UserNotice(title: "Aufnahme beendet", message: "Kein Platz"))
        #expect(notices.pending.count == 2)
        notices.dismissCurrent()
        #expect(notices.current?.title == "Aufnahme beendet")
    }
}

// MARK: - Energy building blocks

@Suite("Energy-saving building blocks")
@MainActor
struct EnergyTests {
    @Test("The time display changes once per second, hidden meters keep their levels")
    func meter() {
        let meter = RecordingMeter()
        let observedChanges = Mutex(0)
        withObservationTracking { _ = meter.elapsedSeconds } onChange: { observedChanges.withLock { $0 += 1 } }
        meter.record(AudioLevel(rms: 0.1, systemRMS: nil, recordedTime: 0.4, hasReceivedSystemAudio: false))
        #expect(observedChanges.withLock { $0 } == 0)
        meter.record(AudioLevel(rms: 0.1, systemRMS: nil, recordedTime: 1.1, hasReceivedSystemAudio: false))
        #expect(observedChanges.withLock { $0 } == 1)
        #expect(meter.elapsedSeconds == 1)

        let levels = meter.levels
        meter.showsLevels = false
        meter.record(AudioLevel(rms: 0.9, systemRMS: nil, recordedTime: 1.2, hasReceivedSystemAudio: false))
        #expect(meter.levels == levels)
        #expect(meter.elapsed == 1.2)
    }

    @Test("Waiting for a cool device returns at once when it is not hot")
    func thermalWait() async {
        guard ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue else { return }
        let start = ContinuousClock.now
        await DeviceLoad.waitWhileHot(maximumWait: .seconds(60))
        // Far below the timeout: it did not wait (other tests may keep the main actor busy).
        #expect(ContinuousClock.now - start < .seconds(20))
    }

    @Test("Vectors stored as Float16 keep their similarities")
    func halfPrecisionVectors() throws {
        var generator = SeededGenerator(seed: 7)
        let a = try #require(EmbeddingVector.normalized((0..<512).map { _ in Float.random(in: -1...1, using: &generator) }))
        let b = try #require(EmbeddingVector.normalized((0..<512).map { _ in Float.random(in: -1...1, using: &generator) }))
        let original = EmbeddingVector(a).similarity(to: EmbeddingVector(b))

        let data = try PropertyListEncoder().encode([EmbeddingVector(a), EmbeddingVector(b)])
        let decoded = try PropertyListDecoder().decode([EmbeddingVector].self, from: data)
        #expect(EmbeddingVector.encodeHalfPrecision(a).count == 512 * 2)
        #expect(abs(decoded[0].similarity(to: decoded[1]) - original) < 0.001)
        #expect(EmbeddingVector.decodeHalfPrecision(Data([1, 2, 3])) == nil)
    }

    @Test("The Whisper runtime is idle and unloaded without a model")
    func whisperRuntimeUse() async throws {
        let runtime = WhisperRuntime(modelStore: WhisperModelStore(downloadBase: try StorageLocations.temporary().whisperModelsDirectory), idleDelay: .milliseconds(10))
        #expect(await !runtime.isInUse)
        await runtime.beginUse()
        #expect(await runtime.isInUse)
        await runtime.unloadIfIdle(reason: "test")
        await runtime.endUse()
        #expect(await !runtime.isInUse)
        #expect(await !runtime.isLoaded)
    }
}
