//
//  RecordingControllerTests.swift
//  NotifyAITests
//
//  The recording's state machine, with fakes for everything that touches hardware or the
//  system (`RecordingPorts.swift`): starting, pausing, interruptions, device failures, a
//  full disk, stopping and discarding.
//

import AudioCapture
import Foundation
import NotifyAICore
@testable import NotifyAIPersistence
@testable import NotifyAIServices
import SwiftData
import Testing

// MARK: - Fakes

/// Records what the controller asks of the recorder and lets the test emit capture events.
@MainActor
private final class FakeRecorder: AudioRecording {
    enum Call: Equatable {
        case start(RecordingAudioSource)
        case pause
        case resume
        case stop
        case reducedLevels(Bool)
        case stopStreaming
    }

    private(set) var calls: [Call] = []
    var recordedTime: TimeInterval = 0
    /// Thrown by the next `resume()`.
    var resumeError: (any Error)?
    private var events: AsyncStream<CaptureEvent>.Continuation?
    private var levels: AsyncStream<AudioLevel>.Continuation?

    func start(writingTo url: URL, configuration: CaptureConfiguration, streamsAudio: Bool) async throws -> AudioCaptureStreams {
        calls.append(.start(configuration.source))
        let (levelStream, levels) = AsyncStream.makeStream(of: AudioLevel.self)
        let (eventStream, events) = AsyncStream.makeStream(of: CaptureEvent.self)
        self.levels = levels
        self.events = events
        return AudioCaptureStreams(chunks: nil, levels: levelStream, events: eventStream)
    }

    func pause() {
        calls.append(.pause)
    }

    func resume() async throws {
        calls.append(.resume)
        if let resumeError {
            self.resumeError = nil
            throw resumeError
        }
    }

    func stop() async -> RecordingResult {
        calls.append(.stop)
        events?.finish()
        levels?.finish()
        return RecordingResult(duration: recordedTime)
    }

    func setReducedLevelUpdates(_ reduced: Bool) {
        calls.append(.reducedLevels(reduced))
    }

    func stopStreamingAudio() {
        calls.append(.stopStreaming)
    }

    /// Delivers a capture event as the real capture would, from its stream.
    func emit(_ event: CaptureEvent) {
        events?.yield(event)
    }
}

private struct FakeMicrophone: MicrophoneAccess {
    let isAllowed: Bool

    func requestAccess() async -> Bool {
        isAllowed
    }
}

@MainActor
private final class FakeSystemActivity: SystemActivityControlling {
    let willSleep = EventChannel<Void>()
    private(set) var isRecordingActivityActive = false

    func beginRecordingActivity() {
        isRecordingActivityActive = true
    }

    func endRecordingActivity() {
        isRecordingActivityActive = false
    }
}

@MainActor
private final class FakeActivity: RecordingActivityPresenting {
    private(set) var title: String?
    private(set) var updates: [Bool] = []
    private(set) var isEnded = false

    func start(title: String) {
        self.title = title
    }

    func update(isPaused: Bool, elapsed: TimeInterval) {
        updates.append(isPaused)
    }

    func end() {
        isEnded = true
    }
}

/// A controller with fakes, an in-memory store and a processing queue with mock engines.
@MainActor
private struct Harness {
    let store: NoteStore
    let processing: ProcessingCoordinator
    let audioSession = AudioSessionController()
    let recorder = FakeRecorder()
    let system = FakeSystemActivity()
    let activity = FakeActivity()
    let controller: RecordingController

    init(microphoneAllowed: Bool = true) throws {
        store = try NoteStore(locations: try StorageLocations.temporary(), inMemory: true)
        let settings = makeIsolatedSettings()
        settings.transcription.liveTranscription = false
        let engine = MockTranscriptionEngine(kind: .appleSpeech)
        let transcription = TranscriptionService(appleSpeech: engine, whisper: engine)
        let summarizer = MockSummarizer()
        processing = ProcessingCoordinator(
            store: store,
            settings: settings,
            transcription: transcription,
            summarization: SummarizationService(languageModel: summarizer, fallback: summarizer, availability: { _ in .available }),
            diarizer: SpeakerDiarizer()
        )
        controller = RecordingController(
            store: store,
            settings: settings,
            transcription: transcription,
            processing: processing,
            audioSession: audioSession,
            devices: RecordingController.Devices(
                recorder: recorder,
                microphone: FakeMicrophone(isAllowed: microphoneAllowed),
                system: system,
                activity: activity
            )
        )
        controller.draft.title = "Weekly"
        controller.draft.consentConfirmed = true
    }

    /// Starts a recording and returns its note.
    func startRecording() async throws -> Note {
        await controller.start()
        #expect(controller.phase == .recording)
        return try #require(store.fetch(FetchDescriptor<Note>()).first)
    }
}

// MARK: - Tests

@Suite("Recording controller", .timeLimit(.minutes(1)))
@MainActor
struct RecordingControllerTests {
    @Test("Starting creates the note, records into it and keeps the system awake")
    func start() async throws {
        let harness = try Harness()
        let note = try await harness.startRecording()

        #expect(note.title == "Weekly")
        #expect(note.status == .recording)
        #expect(harness.recorder.calls.first == .start(.microphone))
        #expect(harness.system.isRecordingActivityActive)
        #expect(harness.activity.title == "Weekly")
        // Queued processing waits while recording.
        #expect(harness.processing.isPaused)
    }

    @Test("A recording needs consent")
    func consentIsRequired() async throws {
        let harness = try Harness()
        harness.controller.draft.consentConfirmed = false
        #expect(!harness.controller.canStart)
        await harness.controller.start()
        #expect(harness.controller.phase == .idle)
        #expect(harness.recorder.calls.isEmpty)
    }

    @Test("Without microphone access nothing is recorded and the user learns why")
    func microphoneDenied() async throws {
        let harness = try Harness(microphoneAllowed: false)
        await harness.controller.start()

        #expect(harness.controller.phase == .idle)
        #expect(harness.controller.errorMessage == RecordingError.microphoneAccessDenied.localizedDescription)
        #expect(harness.recorder.calls.isEmpty)
        #expect(harness.store.fetch(FetchDescriptor<Note>()).isEmpty)
    }

    @Test("Pausing and resuming at the user's request")
    func pauseAndResume() async throws {
        let harness = try Harness()
        _ = try await harness.startRecording()

        await harness.controller.togglePause()
        #expect(harness.controller.phase == .paused)
        #expect(harness.recorder.calls.last == .pause)
        #expect(harness.activity.updates.last == true)

        await harness.controller.togglePause()
        #expect(harness.controller.phase == .recording)
        #expect(harness.recorder.calls.last == .resume)
        #expect(harness.activity.updates.last == false)
    }

    @Test("A device that cannot be restarted keeps the recording paused and says why")
    func resumeFails() async throws {
        let harness = try Harness()
        _ = try await harness.startRecording()
        await harness.controller.togglePause()
        harness.recorder.resumeError = TestError()

        await harness.controller.togglePause()
        #expect(harness.controller.phase == .paused)
        #expect(harness.controller.errorMessage == "Testfehler")
    }

    @Test("An interruption pauses the recording and its end resumes it")
    func interruption() async throws {
        let harness = try Harness()
        _ = try await harness.startRecording()

        harness.audioSession.interruptions.send(.began)
        #expect(harness.controller.phase == .paused)
        #expect(harness.controller.pauseReason == .systemInterruption)

        harness.audioSession.interruptions.send(.ended(shouldResume: true))
        await waitUntil { harness.controller.phase == .recording }
        #expect(harness.controller.pauseReason == nil)
    }

    @Test("A pause the user chose survives the end of an interruption")
    func userPauseWins() async throws {
        let harness = try Harness()
        _ = try await harness.startRecording()
        await harness.controller.togglePause()

        harness.audioSession.interruptions.send(.began)
        harness.audioSession.interruptions.send(.ended(shouldResume: true))
        #expect(harness.controller.phase == .paused)
        #expect(!harness.recorder.calls.contains(.resume))
    }

    @Test("The system going to sleep pauses the recording")
    func systemSleep() async throws {
        let harness = try Harness()
        _ = try await harness.startRecording()

        harness.system.willSleep.send(())
        #expect(harness.controller.phase == .paused)
        #expect(harness.controller.pauseReason == .systemSleep)
    }

    @Test("A failed audio device pauses the recording with the reason")
    func deviceFailure() async throws {
        let harness = try Harness()
        _ = try await harness.startRecording()

        harness.recorder.emit(.inputFailed("USB-Mikrofon getrennt"))
        await waitUntil { harness.controller.pauseReason != nil }
        #expect(harness.controller.phase == .paused)
        #expect(harness.controller.pauseReason == .deviceUnavailable("USB-Mikrofon getrennt"))
    }

    @Test("An almost full disk stops the recording, keeps it and reports why")
    func lowDiskSpace() async throws {
        let harness = try Harness()
        let note = try await harness.startRecording()
        harness.recorder.recordedTime = 90

        let event = await nextEvent(of: harness.controller.events) {
            harness.recorder.emit(.lowDiskSpace(availableBytes: 10_000_000))
        }
        #expect(event == .stoppedAutomatically(noteID: note.id, reason: .lowDiskSpace(availableBytes: 10_000_000)))
        #expect(harness.controller.phase == .idle)
        #expect(harness.controller.automaticallyStoppedNoteID == note.id)
        #expect(note.duration == 90)
        #expect(harness.activity.isEnded)
        #expect(!harness.system.isRecordingActivityActive)
    }

    @Test("Markers are saved at once, stopping hands the note to processing")
    func markersAndStop() async throws {
        let harness = try Harness()
        let note = try await harness.startRecording()
        harness.recorder.recordedTime = 12
        harness.controller.addMarker()
        #expect(note.markers.map(\.time) == [12])

        harness.recorder.recordedTime = 30
        let stoppedID = await harness.controller.stop()
        #expect(stoppedID == note.id)
        #expect(harness.controller.phase == .idle)
        #expect(note.duration == 30)
        #expect(note.status != .recording)
        #expect(!harness.processing.isPaused)
        #expect(harness.activity.isEnded)
        #expect(!harness.system.isRecordingActivityActive)
        // The form is empty for the next recording.
        #expect(harness.controller.draft == RecordingController.Draft())
    }

    @Test("Discarding stops and deletes the recording")
    func discard() async throws {
        let harness = try Harness()
        _ = try await harness.startRecording()

        await harness.controller.discard()
        #expect(harness.controller.phase == .idle)
        #expect(harness.store.fetch(FetchDescriptor<Note>()).isEmpty)
        #expect(harness.recorder.calls.last == .stop)
        #expect(!harness.processing.isPaused)
    }
}
