//
//  ProcessingCoordinator.swift
//  NotifyAI
//

import Foundation
import Observation
import OSLog
#if os(iOS)
import UIKit
#endif

/// Runs the post-recording pipeline: transcription → speakers → summary.
///
/// Jobs run one at a time because transcription and summarization compete for the
/// Neural Engine. Every step saves its result, so a job interrupted by the system
/// continues where it stopped after the next launch (see `resumePendingWork()`).
/// Progress lives only in memory; it is not written to disk on every update.
@MainActor
@Observable
final class ProcessingCoordinator {
    /// Live progress of the note that is currently processed.
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
    }

    private(set) var activities: [UUID: Activity] = [:]

    /// Set while a recording is running; queued jobs wait so live transcription keeps up.
    var isPaused = false {
        didSet {
            if !isPaused { startWorkerIfNeeded() }
        }
    }

    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let transcription: TranscriptionService
    @ObservationIgnored private let summarization: SummarizationService
    @ObservationIgnored private let diarizer: SpeakerDiarizer
    @ObservationIgnored private var queue: [Job] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var currentJob: Task<Void, Never>?
    @ObservationIgnored private var currentNoteID: UUID?
    @ObservationIgnored private let logger = Logger.processing

    init(
        store: NoteStore,
        settings: AppSettings,
        transcription: TranscriptionService,
        summarization: SummarizationService,
        diarizer: SpeakerDiarizer
    ) {
        self.store = store
        self.settings = settings
        self.transcription = transcription
        self.summarization = summarization
        self.diarizer = diarizer
    }

    func enqueue(_ job: Job) {
        guard !queue.contains(job) else { return }
        if let note = store.note(id: job.noteID), !note.status.isProcessing {
            note.status = .queued
            note.statusMessage = nil
            try? store.save()
        }
        queue.append(job)
        activities[job.noteID] = Activity(stage: .queued, progress: nil)
        startWorkerIfNeeded()
    }

    /// Re-queues notes whose processing was interrupted (app terminated, crash).
    func resumePendingWork() {
        let interrupted = store.notes(withStatus: [.queued, .transcribing, .identifyingSpeakers, .summarizing])
        for note in interrupted {
            enqueue(.process(note.id))
        }
        // A note still marked as recording belongs to a session that ended unexpectedly.
        // CAF files stay readable, so the audio recorded so far is processed.
        for note in store.notes(withStatus: [.recording]) {
            note.status = .queued
            try? store.save()
            enqueue(.process(note.id))
        }
    }

    /// Cancels queued and running work for a note, e.g. before deleting it.
    func cancel(noteID: UUID) {
        queue.removeAll { $0.noteID == noteID }
        if currentNoteID == noteID {
            currentJob?.cancel()
        }
        activities[noteID] = nil
    }

    /// Cancels all queued and running work, e.g. before deleting every note.
    func cancelAll() {
        queue.removeAll()
        currentJob?.cancel()
        activities.removeAll()
    }

    // MARK: - Worker

    private func startWorkerIfNeeded() {
        guard worker == nil, !isPaused, !queue.isEmpty else { return }
        worker = Task { [weak self] in
            await self?.drainQueue()
            self?.worker = nil
        }
    }

    private func drainQueue() async {
        while !isPaused, !queue.isEmpty {
            let job = queue.removeFirst()
            currentNoteID = job.noteID
            let task = Task { await self.run(job) }
            currentJob = task
            await withBackgroundExecution(named: "Verarbeitung") {
                await task.value
            }
            currentJob = nil
            currentNoteID = nil
            activities[job.noteID] = nil
        }
    }

    private func run(_ job: Job) async {
        guard let note = store.note(id: job.noteID) else { return }
        do {
            switch job {
            case .process:
                try await process(note, forceTranscription: false, forceSummary: false)
            case .retranscribe:
                try await process(note, forceTranscription: true, forceSummary: true)
            case .resummarize:
                try await process(note, forceTranscription: false, forceSummary: true)
            }
        } catch is CancellationError {
            // Leave the status as it is; the job resumes on the next launch.
            logger.info("Processing was cancelled")
        } catch {
            // A cancelled job may belong to a note that was deleted in the meantime;
            // a deleted model must not be touched again.
            guard !Task.isCancelled, let note = store.note(id: job.noteID) else { return }
            logger.error("Processing failed: \(error.localizedDescription, privacy: .public)")
            note.markFailed(error.localizedDescription)
            try? store.save()
        }
    }

    private func process(_ note: Note, forceTranscription: Bool, forceSummary: Bool) async throws {
        let noteID = note.id

        // 1. Transcription
        if note.kind.hasAudio, forceTranscription || !note.hasTranscript {
            guard let audioURL = store.audioURL(for: note) else {
                throw ProcessingError.missingAudio
            }
            update(note, to: .transcribing, progress: 0)
            let engineKind = settings.engine
            let options = TranscriptionOptions(language: note.language, whisperModel: settings.whisperModel)
            let segments = try await transcription.engine(for: engineKind).transcribeFile(
                at: audioURL,
                options: options
            ) { [weak self] fraction in
                Task { @MainActor in self?.reportProgress(fraction, for: noteID) }
            }
            try Task.checkCancellation()
            try await saveTranscript(segments, engine: engineKind, to: note)
            note.summary = nil
        }

        guard note.kind.hasAudio ? note.hasTranscript : !note.bodyText.isEmpty else {
            throw ProcessingError.noSpeechDetected
        }

        // 2. Speakers. A microphone + system audio recording knows who spoke from which
        //    source ("Ich" / "Andere"), which is far more reliable than the experimental
        //    voice-based detection, so it takes precedence.
        let needsSpeakers = note.kind.hasAudio && (forceTranscription || note.summary == nil)
        if needsSpeakers, settings.speakersFromAudioSource, let activity = note.sourceActivity {
            update(note, to: .identifyingSpeakers, progress: nil)
            let segments = SourceSpeakerAttribution.assign(
                activity,
                to: note.decodedTranscript(),
                othersLabel: SourceSpeakerAttribution.othersLabel(participants: note.participants)
            )
            try await saveTranscript(segments, engine: note.transcriptionEngine, to: note)
        } else if needsSpeakers, settings.speakerDetection, let audioURL = store.audioURL(for: note) {
            update(note, to: .identifyingSpeakers, progress: nil)
            let turns = try await diarizer.turns(forAudioAt: audioURL)
            try Task.checkCancellation()
            if !turns.isEmpty {
                let segments = SpeakerDiarizer.assignSpeakers(turns, to: note.decodedTranscript())
                try await saveTranscript(segments, engine: note.transcriptionEngine, to: note)
            }
        }

        // 3. Summary
        if forceSummary || note.summary == nil {
            update(note, to: .summarizing, progress: nil)
            let segments = note.decodedTranscript()
            let request = SummaryRequest(
                text: note.bodyText,
                language: note.language,
                focus: note.focus,
                kind: note.kind,
                markedPassages: note.markers.map {
                    Transcript.text(in: $0.highlightRange(duration: note.duration), of: segments)
                }
            )
            let summary = try await summarization.summarize(request) { [weak self] fraction in
                Task { @MainActor in self?.reportProgress(fraction, for: noteID) }
            }
            try Task.checkCancellation()
            note.summary = summary
            if !note.isTitleUserDefined, let title = summary.suggestedTitle {
                note.title = title
            }
        }

        note.status = .ready
        note.statusMessage = nil
        try store.save()
    }

    /// Encodes the transcript off the main actor and stores it on the note.
    private func saveTranscript(_ segments: [TranscriptSegment], engine: TranscriptionEngineKind?, to note: Note) async throws {
        let normalized = Transcript.normalized(segments)
        guard !normalized.isEmpty else { throw ProcessingError.noSpeechDetected }
        let (data, text) = try await Task.detached(priority: .userInitiated) {
            (try Transcript.encode(normalized), Transcript.plainText(of: normalized))
        }.value
        try Task.checkCancellation()
        note.setTranscript(encoded: data, plainText: text, engine: engine)
        try store.save()
    }

    private func update(_ note: Note, to stage: NoteStatus, progress: Double?) {
        note.status = stage
        note.statusMessage = nil
        try? store.save()
        activities[note.id] = Activity(stage: stage, progress: progress)
    }

    private func reportProgress(_ fraction: Double, for noteID: UUID) {
        guard var activity = activities[noteID] else { return }
        let clamped = min(max(fraction, 0), 1)
        // Skip tiny steps to avoid needless view updates.
        if let current = activity.progress, abs(current - clamped) < 0.01 { return }
        activity.progress = clamped
        activities[noteID] = activity
    }

    /// Asks the system for extra time so processing can finish after the user leaves the app
    /// (iOS), and prevents App Nap from throttling it (macOS).
    private func withBackgroundExecution(named name: String, _ work: () async -> Void) async {
        #if os(iOS)
        let task = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                self?.currentJob?.cancel()
            }
        }
        await work()
        UIApplication.shared.endBackgroundTask(task)
        #else
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: name)
        await work()
        ProcessInfo.processInfo.endActivity(activity)
        #endif
    }
}

enum ProcessingError: LocalizedError {
    case missingAudio
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .missingAudio: "Die Audiodatei dieser Notiz fehlt."
        case .noSpeechDetected: "In der Aufnahme wurde keine Sprache erkannt."
        }
    }
}
