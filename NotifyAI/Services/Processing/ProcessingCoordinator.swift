//
//  ProcessingCoordinator.swift
//  NotifyAI
//

import Foundation
import NotifyAICore
import Observation
import OSLog

/// Runs processing jobs one at a time and publishes their progress.
///
/// Jobs run serially because transcription and summarization compete for the Neural
/// Engine. What a job does is defined by `NoteProcessingPipeline`; this type owns the
/// queue, the progress shown in the UI, interruptions and background time. Progress lives
/// only in memory; it is not written to disk on every update.
///
/// Two things stop the worker, and each has its own way back:
/// - A recording (`pauseForRecording`, `resumeAfterRecording`). With live transcription the
///   running job is interrupted too, because it would compete for the Neural Engine.
/// - The end of background time on iOS (`interruptCurrentJob`). The worker stays stopped
///   until the app is active again or a background task grants new time; both call
///   `resumeQueuedWork()`.
/// An interrupted job goes back to the front of the queue and continues from its last
/// saved step (transcript, chapter digests).
@MainActor
@Observable
final class ProcessingCoordinator {
    /// Live progress of a queued or running note.
    struct Activity: Equatable {
        var stage: NoteStatus
        /// 0…1, or `nil` if the stage cannot report progress.
        var progress: Double?
    }

    enum Job: Equatable {
        /// Runs all missing steps for the note.
        case process(UUID)
        /// Discards the transcript and summary and transcribes again.
        case retranscribe(UUID)
        /// Creates a new summary from the existing transcript.
        case resummarize(UUID)

        var noteID: UUID {
            switch self {
            case .process(let id), .retranscribe(let id), .resummarize(let id): id
            }
        }

        var options: ProcessingOptions {
            switch self {
            case .process: ProcessingOptions()
            case .retranscribe: ProcessingOptions(forceTranscription: true, forceSummary: true)
            case .resummarize: ProcessingOptions(forceSummary: true)
            }
        }
    }

    private(set) var activities: [UUID: Activity] = [:]
    /// Jobs finished since the queue was last empty.
    private(set) var completedInBatch = 0

    /// Set while a recording is running; queued jobs wait so live transcription keeps up.
    private(set) var isPaused = false
    /// Set when the system ended the background time; cleared by `resumeQueuedWork()`.
    private(set) var isSuspended = false

    /// Whether jobs are queued or running.
    var hasPendingWork: Bool { !activities.isEmpty }

    /// Overall progress of the pending work (0…1): finished jobs plus the running job's progress.
    var overallProgress: Double {
        let total = max(activities.count + completedInBatch, 1)
        let running = current.flatMap { activities[$0.job.noteID]?.progress } ?? 0
        return min(1, (Double(completedInBatch) + running) / Double(total))
    }

    /// Stage of the running job, for status texts.
    var currentStage: NoteStatus? {
        current.flatMap { activities[$0.job.noteID]?.stage }
    }

    /// Called when a note is finished, e.g. to add it to the search index.
    @ObservationIgnored var onNoteReady: ((UUID) -> Void)?
    /// Called when a job starts, with the note's audio duration (0 for documents). Used to
    /// ask iOS for continued background processing of long recordings.
    @ObservationIgnored var onJobStarted: ((UUID, TimeInterval) -> Void)?
    @ObservationIgnored let digestStore: ChapterDigestStore

    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let pipeline: NoteProcessingPipeline
    @ObservationIgnored private var queue: [Job] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var current: (job: Job, task: Task<Void, Never>)?
    @ObservationIgnored private let logger = Logger.processing

    init(
        store: NoteStore,
        settings: AppSettings,
        transcription: TranscriptionService,
        summarization: SummarizationService,
        diarizer: SpeakerDiarizer,
        embedder: SentenceEmbedder = SentenceEmbedder(),
        digestStore: ChapterDigestStore = ChapterDigestStore(directory: nil)
    ) {
        self.store = store
        self.digestStore = digestStore
        pipeline = NoteProcessingPipeline(
            transcription: TranscriptionStep(transcription: transcription, settings: settings.transcription),
            speakers: SpeakerStep(settings: settings.analysis, diarizer: diarizer),
            summary: SummaryStep(summarization: summarization, digestStore: digestStore, embedder: embedder)
        )
    }

    // MARK: - Queue

    func enqueue(_ job: Job) {
        guard !queue.contains(job) else { return }
        if let note = store.note(id: job.noteID), !note.status.isProcessing {
            note.status = .queued
            note.statusMessage = nil
            store.saveReportingErrors()
        }
        queue.append(job)
        activities[job.noteID] = Activity(stage: .queued, progress: nil)
        startWorkerIfNeeded()
    }

    /// Re-queues notes whose processing was interrupted (app terminated, crash).
    func resumePendingWork() {
        for note in store.notes(withStatus: [.queued, .transcribing, .identifyingSpeakers, .summarizing]) {
            enqueue(.process(note.id))
        }
        // A note still marked as recording belongs to a session that ended unexpectedly.
        // CAF files stay readable, so the audio recorded so far is processed.
        for note in store.notes(withStatus: [.recording]) {
            note.status = .queued
            store.saveReportingErrors()
            enqueue(.process(note.id))
        }
    }

    /// Continues queued work: when the app becomes active again or a background task
    /// grants time. Also lifts the suspension after `interruptCurrentJob()`.
    func resumeQueuedWork() {
        if isSuspended {
            logger.info("Continuing the interrupted work")
        }
        isSuspended = false
        startWorkerIfNeeded()
    }

    /// Called when a recording starts: queued jobs wait until it ends.
    /// - Parameter interruptingRunningJob: Also stop the running job, so live transcription
    ///   has the Neural Engine to itself. The job continues from its last saved step when
    ///   the recording ends.
    func pauseForRecording(interruptingRunningJob: Bool) {
        isPaused = true
        if interruptingRunningJob, current != nil {
            logger.info("A recording started; the running job continues after it")
            requeueCurrentJob()
        }
    }

    /// Called when the recording ended or was discarded.
    func resumeAfterRecording() {
        isPaused = false
        startWorkerIfNeeded()
    }

    /// Cancels queued and running work for a note, e.g. before deleting it.
    func cancel(noteID: UUID) {
        queue.removeAll { $0.noteID == noteID }
        if current?.job.noteID == noteID {
            current?.task.cancel()
        }
        activities[noteID] = nil
    }

    /// Stops the running job and the worker because the system ends background time. The
    /// job is queued again and continues from its last saved step (transcript, chapter
    /// digests) once `resumeQueuedWork()` is called.
    func interruptCurrentJob() {
        isSuspended = true
        guard current != nil else { return }
        requeueCurrentJob()
        logger.info("Interrupted the running job; it continues when the app is active again")
    }

    /// Cancels the running job and puts it back at the front of the queue.
    private func requeueCurrentJob() {
        guard let current else { return }
        current.task.cancel()
        if !queue.contains(current.job) {
            queue.insert(current.job, at: 0)
        }
        activities[current.job.noteID] = Activity(stage: .queued, progress: nil)
    }

    /// Cancels all queued and running work, e.g. before deleting every note.
    func cancelAll() {
        queue.removeAll()
        current?.task.cancel()
        activities.removeAll()
    }

    // MARK: - Worker

    private func startWorkerIfNeeded() {
        guard worker == nil, !isPaused, !isSuspended, !queue.isEmpty else { return }
        worker = Task { [weak self] in
            await self?.drainQueue()
            self?.worker = nil
        }
    }

    /// Runs jobs until the queue is empty, a recording pauses the work or background time
    /// ends. The conditions are checked again after an interrupted job: if the app became
    /// active while the job was winding down, the worker simply continues.
    private func drainQueue() async {
        while !isPaused, !isSuspended, !queue.isEmpty {
            let job = queue.removeFirst()
            if let note = store.note(id: job.noteID) {
                onJobStarted?(job.noteID, note.kind.hasAudio ? note.duration : 0)
            }
            let task = Task { await self.run(job) }
            current = (job, task)
            await BackgroundExecution.run(named: "Verarbeitung", onExpiration: { [weak self] in
                // Continues from its last saved step when the app is active again.
                self?.interruptCurrentJob()
            }) {
                await task.value
            }
            let wasRequeued = task.isCancelled && queue.first == job
            current = nil
            if wasRequeued {
                // Interrupted by a recording or the end of background time: the job waits
                // at the front of the queue; the loop condition decides whether to go on.
                continue
            }
            activities[job.noteID] = nil
            completedInBatch += 1
        }
        if queue.isEmpty {
            completedInBatch = 0
        }
    }

    private func run(_ job: Job) async {
        guard let note = store.note(id: job.noteID) else { return }
        do {
            try await pipeline.run(note, options: job.options, context: makeContext(for: job.noteID))
            onNoteReady?(job.noteID)
        } catch is CancellationError {
            // Leave the status as it is; the job resumes later.
            logger.info("Processing was cancelled")
        } catch {
            // A cancelled job may belong to a note that was deleted in the meantime;
            // a deleted model must not be touched again.
            guard !Task.isCancelled, let note = store.note(id: job.noteID) else { return }
            logger.error("Processing failed: \(error.localizedDescription, privacy: .public)")
            note.markFailed(error.localizedDescription)
            store.saveReportingErrors()
        }
    }

    // MARK: - Progress

    private func makeContext(for noteID: UUID) -> ProcessingContext {
        ProcessingContext(
            store: store,
            noteID: noteID,
            setStage: { [weak self] stage, progress in
                self?.setStage(stage, progress: progress, for: noteID)
            },
            progress: { [weak self] fraction in
                Task { @MainActor in self?.reportProgress(fraction, for: noteID) }
            }
        )
    }

    private func setStage(_ stage: NoteStatus, progress: Double?, for noteID: UUID) {
        if let note = store.note(id: noteID) {
            note.status = stage
            note.statusMessage = nil
            store.saveReportingErrors()
        }
        activities[noteID] = Activity(stage: stage, progress: progress)
    }

    private func reportProgress(_ fraction: Double, for noteID: UUID) {
        guard var activity = activities[noteID] else { return }
        let clamped = min(max(fraction, 0), 1)
        // Skip tiny steps to avoid needless view updates.
        if let current = activity.progress, abs(current - clamped) < 0.01 { return }
        activity.progress = clamped
        activities[noteID] = activity
    }
}
