//
//  RecordingController.swift
//  NotifyAI
//

import Foundation
import Observation
import OSLog

/// Drives a recording session: start, pause, markers, interruptions and stop.
///
/// The details live in collaborators: `AudioRecorder` captures, `RecordingMeter` holds the
/// levels and time, `LiveTranscriptFeed` the live transcript, `RecordingNoteWriter` creates
/// and completes the note. One instance exists per app; the main window, the macOS menu bar
/// and the Live Activity all show its state.
@MainActor
@Observable
final class RecordingController {
    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case paused
        /// Stopped; the remaining audio is being transcribed.
        case finishing
    }

    /// What the user entered before starting.
    struct Draft {
        var title = ""
        var focus: RecordingFocus = .general
        var participants = ""
        var consentConfirmed = false
    }

    /// After this much recorded time without any system audio, the UI suggests checking the permission.
    static let systemAudioHintDelay: TimeInterval = 10

    var draft = Draft()
    private(set) var phase: Phase = .idle
    /// Source of the running recording.
    private(set) var audioSource: RecordingAudioSource = .microphone
    /// The app whose audio is recorded, for display.
    private(set) var systemAudioTarget: SystemAudioTarget = .allApps
    private(set) var markers: [Marker] = []
    /// Set briefly after a marker was added, for visual feedback.
    private(set) var lastMarker: Marker?
    private(set) var errorMessage: String?
    private(set) var interruptionMessage: String?

    let meter = RecordingMeter()
    let transcript = LiveTranscriptFeed()

    var isActive: Bool { phase != .idle }
    var canStart: Bool { phase == .idle && draft.consentConfirmed }

    /// No system audio arrived yet: either nothing is playing, or macOS denied the permission.
    var isMissingSystemAudio: Bool {
        audioSource.usesSystemAudio && isActive && !meter.hasReceivedSystemAudio && meter.elapsed >= Self.systemAudioHintDelay
    }

    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let transcription: TranscriptionService
    @ObservationIgnored private let processing: ProcessingCoordinator
    @ObservationIgnored private let audioSession: AudioSessionController
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let liveActivity = RecordingLiveActivity()
    @ObservationIgnored private let noteWriter: RecordingNoteWriter
    /// Condenses finished chapters of long recordings while recording; `nil` disables it.
    @ObservationIgnored private let liveChapters: LiveChapterSummarizer?
    @ObservationIgnored private var noteID: UUID?
    /// Consume the recorder's level and chunk streams; they end when the recorder stops.
    @ObservationIgnored private var captureTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var lastMarkerReset: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger.audio

    init(
        store: NoteStore,
        settings: AppSettings,
        transcription: TranscriptionService,
        processing: ProcessingCoordinator,
        audioSession: AudioSessionController,
        liveChapters: LiveChapterSummarizer? = nil
    ) {
        self.store = store
        self.settings = settings
        self.transcription = transcription
        self.processing = processing
        self.audioSession = audioSession
        self.liveChapters = liveChapters
        noteWriter = RecordingNoteWriter(store: store)
        audioSession.onInterruption = { [weak self] interruption in
            self?.handleInterruption(interruption)
        }
        transcript.onSegmentsChanged = { [weak liveChapters] segments in
            liveChapters?.transcriptDidChange(segments)
        }
    }

    // MARK: - Session lifecycle

    func start() async {
        guard canStart else { return }
        errorMessage = nil
        interruptionMessage = nil
        phase = .starting

        let configuration = settings.recording.captureConfiguration
        if configuration.source.usesMicrophone, !(await MicrophonePermission.request()) {
            phase = .idle
            errorMessage = "Kein Zugriff auf das Mikrofon. Bitte erlaube den Zugriff in den Systemeinstellungen."
            return
        }

        let note = noteWriter.makeNote(draft: draft, configuration: configuration, language: settings.transcription.language)
        do {
            try store.insert(note)
            try audioSession.activateForRecording()
            let url = store.locations.audioURL(fileName: NoteStore.recordingFileName(for: note.id))
            let streams = try await recorder.start(writingTo: url, configuration: configuration)
            noteID = note.id
            audioSource = configuration.source
            systemAudioTarget = configuration.systemAudioTarget
            meter.reset()
            markers = []
            lastMarker = nil
            phase = .recording
            liveActivity.start(title: note.title)
            processing.isPaused = true
            consume(streams)
            startLiveTranscription(for: note)
        } catch {
            logger.error("Starting the recording failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
            try? store.delete(note)
            audioSession.deactivate()
            phase = .idle
        }
    }

    func togglePause() {
        switch phase {
        case .recording:
            recorder.pause()
            phase = .paused
        case .paused:
            do {
                try recorder.resume()
                interruptionMessage = nil
                phase = .recording
            } catch {
                errorMessage = error.localizedDescription
            }
        default:
            return
        }
        liveActivity.update(isPaused: phase == .paused, elapsed: recorder.recordedTime)
    }

    /// Flags the current moment as important. The transcript later highlights
    /// `Marker.highlightPadding` seconds before and after it.
    func addMarker() {
        guard phase == .recording || phase == .paused, let noteID, let note = store.note(id: noteID) else { return }
        let marker = Marker(time: recorder.recordedTime)
        markers.append(marker)
        // Persist immediately so the marker survives an unexpected termination.
        note.markers = markers
        try? store.save()
        liveChapters?.markers = markers

        lastMarker = marker
        lastMarkerReset?.cancel()
        lastMarkerReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.lastMarker = nil
        }
    }

    /// Stops the recording, finishes live transcription and hands the note to processing.
    /// - Returns: The identifier of the saved note.
    @discardableResult
    func stop() async -> UUID? {
        guard phase == .recording || phase == .paused, let noteID else { return nil }
        phase = .finishing
        let result = await recorder.stop()
        audioSession.deactivate()
        liveActivity.end()
        // Chapters condensed so far stay in the digest store; the rest is done by the processing.
        liveChapters?.stop()

        // The recorder finished its streams; wait until all audio reached the live session.
        for task in captureTasks { await task.value }
        let finalTranscript = await transcript.finish()
        await noteWriter.complete(
            noteID: noteID,
            result: result,
            markers: markers,
            transcript: finalTranscript,
            engine: transcript.engineKind
        )

        reset()
        processing.isPaused = false
        processing.enqueue(.process(noteID))
        return noteID
    }

    /// Stops and deletes the recording.
    func discard() async {
        guard isActive, let noteID else { return }
        await recorder.stop()
        audioSession.deactivate()
        liveActivity.end()
        // Digests of this recording are removed together with the note (`onNotesDeleted`).
        liveChapters?.stop()
        captureTasks.forEach { $0.cancel() }
        await transcript.cancel()
        if let note = store.note(id: noteID) {
            try? store.delete(note)
        }
        reset()
        processing.isPaused = false
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: - Private

    private func startLiveTranscription(for note: Note) {
        guard settings.transcription.liveTranscription else {
            transcript.reset()
            return
        }
        let kind = settings.transcription.engine
        transcript.start(engine: transcription.engine(for: kind), kind: kind, options: settings.transcription.options)
        if settings.analysis.summarizeWhileRecording {
            liveChapters?.start(noteID: note.id, context: SummaryRequest(
                text: "",
                language: note.language,
                focus: note.focus,
                kind: .recording,
                markedPassages: [],
                recordedAt: note.createdAt,
                participants: note.participants
            ))
        }
    }

    private func consume(_ streams: AudioCaptureStreams) {
        captureTasks = [
            Task { [weak self] in
                for await level in streams.levels {
                    self?.meter.record(level)
                }
            },
            Task { [weak self] in
                for await chunk in streams.chunks {
                    await self?.transcript.append(chunk)
                }
            },
        ]
    }

    private func handleInterruption(_ interruption: AudioSessionController.Interruption) {
        guard phase == .recording || phase == .paused else { return }
        switch interruption {
        case .began:
            recorder.pause()
            phase = .paused
            interruptionMessage = "Die Aufnahme wurde vom System unterbrochen, z. B. durch einen Anruf."
            liveActivity.update(isPaused: true, elapsed: recorder.recordedTime)
        case .ended(let shouldResume):
            if shouldResume, phase == .paused {
                togglePause()
            }
        }
    }

    private func reset() {
        meter.reset()
        transcript.reset()
        noteID = nil
        captureTasks = []
        markers = []
        lastMarker = nil
        interruptionMessage = nil
        audioSource = .microphone
        systemAudioTarget = .allApps
        draft = Draft()
        phase = .idle
    }
}
