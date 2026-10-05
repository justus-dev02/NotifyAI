//
//  InterruptedProcessingTests.swift
//  NotifyAITests
//
//  Processing jobs stopped by a recording or by the end of background time, and how they
//  continue from their last saved step.
//

import Foundation
@testable import NotifyAI
import NotifyAICore
@testable import NotifyAIPersistence
@testable import NotifyAIServices
import Synchronization
import Testing

// MARK: - Interrupted processing

/// Transcribes only after `open()`; counts how often a transcription started.
final class GatedTranscriptionEngine: TranscriptionEngine {
    let kind: TranscriptionEngineKind = .appleSpeech
    /// `false` imitates WhisperKit and the language model: cancellation takes effect only
    /// when the current call returns.
    let respondsToCancellation: Bool
    /// Signalled when the first transcription started.
    let firstStart = TestGate()
    private let state = Mutex<(started: Int, isOpen: Bool, waiting: [CheckedContinuation<Void, Never>])>((0, false, []))

    init(respondsToCancellation: Bool = true) {
        self.respondsToCancellation = respondsToCancellation
    }

    var started: Int { state.withLock { $0.started } }

    /// Lets every waiting and later transcription finish.
    func open() {
        let waiting = state.withLock { state in
            state.isOpen = true
            defer { state.waiting = [] }
            return state.waiting
        }
        waiting.forEach { $0.resume() }
    }

    func startLiveSession(options: TranscriptionOptions) async throws -> any LiveTranscriptionSession {
        throw TranscriptionError.speechAssetsUnavailable
    }

    func transcribeFile(at url: URL, options: TranscriptionOptions, progress: @escaping @Sendable (Double) -> Void) async throws -> [TranscriptSegment] {
        state.withLock { $0.started += 1 }
        firstStart.signal()
        if respondsToCancellation {
            await withTaskCancellationHandler {
                await waitUntilOpen()
            } onCancel: {
                resumeWaiting()
            }
            try Task.checkCancellation()
        } else {
            // Not cancelled together with the job.
            await waitUntilOpen()
        }
        return [TranscriptSegment(start: 0, end: 2, text: "Hallo zusammen.")]
    }

    private func waitUntilOpen() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state in
                let cancelled = respondsToCancellation && Task.isCancelled
                if !state.isOpen, !cancelled {
                    state.waiting.append(continuation)
                }
                return state.isOpen || cancelled
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    private func resumeWaiting() {
        let waiting = state.withLock { state in
            defer { state.waiting = [] }
            return state.waiting
        }
        waiting.forEach { $0.resume() }
    }
}

@Suite("Interrupted processing")
@MainActor
struct InterruptedProcessingTests {
    private let store: NoteStore
    private let settings: AppSettings

    init() throws {
        store = try NoteStore(locations: try StorageLocations.temporary(), inMemory: true)
        settings = makeIsolatedSettings()
    }

    private func makeCoordinator(_ engine: any TranscriptionEngine) -> ProcessingCoordinator {
        let summarizer = MockSummarizer()
        return ProcessingCoordinator(
            store: store,
            settings: settings,
            transcription: TranscriptionService(appleSpeech: engine, whisper: engine),
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

    @Test("A recording with live transcription stops the running job; it continues afterwards")
    func recordingInterruptsRunningJob() async throws {
        let engine = GatedTranscriptionEngine()
        let coordinator = makeCoordinator(engine)
        let note = try makeAudioNote()
        coordinator.enqueue(.process(note.id))
        await engine.firstStart.wait()

        coordinator.pauseForRecording(interruptingRunningJob: true)
        engine.open()
        // The worker has stopped: nothing can run any more until the recording ends.
        await waitUntil { coordinator.runningNoteID == nil }
        // The job was stopped and waits; it did not finish during the recording.
        #expect(note.status != .ready)
        #expect(coordinator.hasPendingWork)
        #expect(engine.started == 1)

        coordinator.resumeAfterRecording()
        await waitUntil { note.status == .ready }
        #expect(engine.started == 2)
        // The note is ready before the worker clears its bookkeeping, so wait for that too.
        await waitUntil { !coordinator.hasPendingWork }
    }

    @Test("Without live transcription the running job finishes, queued jobs wait")
    func recordingWithoutLiveTranscription() async throws {
        let engine = GatedTranscriptionEngine()
        let coordinator = makeCoordinator(engine)
        let running = try makeAudioNote()
        let queued = try makeAudioNote()
        coordinator.enqueue(.process(running.id))
        await engine.firstStart.wait()

        coordinator.pauseForRecording(interruptingRunningJob: false)
        coordinator.enqueue(.process(queued.id))
        engine.open()
        await waitUntil { running.status == .ready }
        // The worker finished the running job and stopped because of the recording.
        await waitUntil { coordinator.runningNoteID == nil }
        #expect(queued.status == .queued)
        #expect(engine.started == 1)

        coordinator.resumeAfterRecording()
        await waitUntil { queued.status == .ready }
    }

    @Test("Work stopped when background time ended waits, and continues when the app is active")
    func suspendedWorkContinues() async throws {
        let engine = GatedTranscriptionEngine()
        let coordinator = makeCoordinator(engine)
        let note = try makeAudioNote()
        coordinator.enqueue(.process(note.id))
        await engine.firstStart.wait()

        coordinator.interruptCurrentJob()
        engine.open()
        await waitUntil { coordinator.runningNoteID == nil }
        #expect(coordinator.isSuspended)
        #expect(note.status != .ready)
        #expect(engine.started == 1)

        coordinator.resumeQueuedWork()
        #expect(!coordinator.isSuspended)
        await waitUntil { note.status == .ready }
        #expect(engine.started == 2)
    }

    @Test("Becoming active while the interrupted job still winds down continues the work")
    func activeWhileWindingDown() async throws {
        let engine = GatedTranscriptionEngine(respondsToCancellation: false)
        let coordinator = makeCoordinator(engine)
        let note = try makeAudioNote()
        coordinator.enqueue(.process(note.id))
        await engine.firstStart.wait()

        // The job ignores the cancellation until its current call returns.
        coordinator.interruptCurrentJob()
        coordinator.resumeQueuedWork()
        engine.open()
        await waitUntil { note.status == .ready }
        // The note is ready before the worker clears its bookkeeping, so wait for that too.
        await waitUntil { !coordinator.hasPendingWork }
    }

    @Test("The app resumes suspended processing when it becomes active")
    func appEnvironmentResumesOnActivation() throws {
        let environment = try AppEnvironment(settings: makeIsolatedSettings(), locations: try StorageLocations.temporary(), inMemory: true)
        environment.services.processing.interruptCurrentJob()
        #expect(environment.services.processing.isSuspended)
        environment.lifecycle.didBecomeActive()
        #expect(!environment.services.processing.isSuspended)
    }
}
