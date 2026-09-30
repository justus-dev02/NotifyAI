//
//  RecordingController.swift
//  NotifyAI
//

import AudioCapture
import Foundation
import NotifyAICore
import Observation
import OSLog
#if os(macOS)
import AppKit
#endif

/// Drives a recording session: start, pause, markers, interruptions and stop.
///
/// The details live in collaborators: `AudioRecorder` captures, `RecordingMeter` holds the
/// levels and time, `LiveTranscriptFeed` the live transcript, `RecordingNoteWriter` creates
/// and completes the note. One instance exists per app; the main window, the macOS menu bar
/// and the Live Activity all show its state.
///
/// Robustness:
/// - A write error or an almost full disk stops the recording; what was recorded is kept
///   and the user is told why (`UserNotices`).
/// - On the Mac, App Nap and idle sleep are suspended while recording. When the Mac goes
///   to sleep anyway (lid closed), the recording pauses and says so.
/// - Live transcription that falls too far behind is abandoned; the file is transcribed
///   after the recording.
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
    static let systemAudioHintDelay = 10

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
    /// The note of a recording that stopped on its own (full disk, write error). The
    /// recording screen closes and opens the note.
    private(set) var automaticallyStoppedNoteID: UUID?

    let meter = RecordingMeter()
    let transcript = LiveTranscriptFeed()

    var isActive: Bool { phase != .idle }
    var canStart: Bool { phase == .idle && draft.consentConfirmed }

    /// No system audio arrived yet: either nothing is playing, or macOS denied the permission.
    var isMissingSystemAudio: Bool {
        audioSource.usesSystemAudio && isActive && !meter.hasReceivedSystemAudio && meter.elapsedSeconds >= Self.systemAudioHintDelay
    }

    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let transcription: TranscriptionService
    @ObservationIgnored private let processing: ProcessingCoordinator
    @ObservationIgnored private let audioSession: AudioSessionController
    @ObservationIgnored private let notices: UserNotices?
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let liveActivity = RecordingLiveActivity()
    @ObservationIgnored private let noteWriter: RecordingNoteWriter
    /// Condenses finished chapters of long recordings while recording; `nil` disables it.
    @ObservationIgnored private let liveChapters: LiveChapterSummarizer?
    @ObservationIgnored private var noteID: UUID?
    /// Consume the recorder's streams; they end when the recorder stops.
    @ObservationIgnored private var captureTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var lastMarkerReset: Task<Void, Never>?
    /// Identifiers of the level meters currently on screen.
    @ObservationIgnored private var visibleMeters: Set<String> = []
    @ObservationIgnored private let logger = Logger.audio
    #if os(macOS)
    /// Keeps App Nap from throttling the capture and the Mac from idle sleep while recording.
    @ObservationIgnored private var activity: (any NSObjectProtocol)?
    @ObservationIgnored private var sleepObservers: [any NSObjectProtocol] = []
    #endif

    init(
        store: NoteStore,
        settings: AppSettings,
        transcription: TranscriptionService,
        processing: ProcessingCoordinator,
        audioSession: AudioSessionController,
        notices: UserNotices? = nil,
        liveChapters: LiveChapterSummarizer? = nil
    ) {
        self.store = store
        self.settings = settings
        self.transcription = transcription
        self.processing = processing
        self.audioSession = audioSession
        self.notices = notices
        self.liveChapters = liveChapters
        noteWriter = RecordingNoteWriter(store: store)
        audioSession.onInterruption = { [weak self] interruption in
            self?.handleInterruption(interruption)
        }
        transcript.onSegmentsChanged = { [weak liveChapters] segments in
            liveChapters?.transcriptDidChange(segments)
        }
        transcript.onFellBehind = { [weak self] in
            // Nobody consumes the audio stream any more; stop filling it.
            self?.recorder.stopStreamingAudio()
        }
        observeSystemSleep()
    }

    // MARK: - Session lifecycle

    func start() async {
        guard canStart else { return }
        errorMessage = nil
        interruptionMessage = nil
        automaticallyStoppedNoteID = nil
        phase = .starting

        let configuration = settings.recording.captureConfiguration
        if configuration.source.usesMicrophone, !(await MicrophonePermission.request()) {
            phase = .idle
            errorMessage = String(localized: "Kein Zugriff auf das Mikrofon. Bitte erlaube den Zugriff in den Systemeinstellungen.")
            return
        }

        let note = noteWriter.makeNote(draft: draft, configuration: configuration, language: settings.transcription.language)
        do {
            try store.insert(note)
            try audioSession.activateForRecording()
            let url = store.locations.audioURL(fileName: NoteStore.recordingFileName(for: note.id))
            let streams = try await recorder.start(
                writingTo: url,
                configuration: configuration,
                streamsAudio: settings.transcription.liveTranscription
            )
            noteID = note.id
            audioSource = configuration.source
            systemAudioTarget = configuration.systemAudioTarget
            meter.reset()
            applyMeterVisibility()
            markers = []
            lastMarker = nil
            phase = .recording
            beginSystemActivity()
            liveActivity.start(title: note.title)
            processing.isPaused = true
            consume(streams)
            startLiveTranscription(for: note)
        } catch {
            logger.error("Starting the recording failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
            store.deleteReportingErrors(note)
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
        store.saveReportingErrors()
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
        eventTask?.cancel()
        eventTask = nil
        audioSession.deactivate()
        liveActivity.end()
        endSystemActivity()
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
        eventTask?.cancel()
        eventTask = nil
        audioSession.deactivate()
        liveActivity.end()
        endSystemActivity()
        // Digests of this recording are removed together with the note (`onNotesDeleted`).
        liveChapters?.stop()
        captureTasks.forEach { $0.cancel() }
        await transcript.cancel()
        if let note = store.note(id: noteID) {
            store.deleteReportingErrors(note)
        }
        reset()
        processing.isPaused = false
    }

    func dismissError() {
        errorMessage = nil
    }

    /// Called by the recording screen after it reacted to an automatic stop.
    func acknowledgeAutomaticStop() {
        automaticallyStoppedNoteID = nil
    }

    // MARK: - Meters

    /// Level meters register while they are on screen. Without any, levels are published
    /// only once per second (for the elapsed time) instead of ten times.
    func setMeterVisible(_ visible: Bool, id: String) {
        if visible {
            visibleMeters.insert(id)
        } else {
            visibleMeters.remove(id)
        }
        applyMeterVisibility()
    }

    private func applyMeterVisibility() {
        let isShown = !visibleMeters.isEmpty
        meter.showsLevels = isShown
        recorder.setReducedLevelUpdates(!isShown)
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
        ]
        if let chunks = streams.chunks {
            captureTasks.append(Task { [weak self] in
                for await chunk in chunks {
                    await self?.transcript.append(chunk)
                }
            })
        }
        eventTask = Task { [weak self] in
            for await event in streams.events {
                self?.handle(event)
            }
        }
    }

    /// The capture cannot continue: stop and keep what was recorded. The stop runs in its
    /// own task, because stopping cancels the task that delivers the events.
    private func handle(_ event: CaptureEvent) {
        Task { await stopAutomatically(after: event) }
    }

    private func stopAutomatically(after event: CaptureEvent) async {
        guard phase == .recording || phase == .paused else { return }
        let message = switch event {
        case .writeFailed(let reason):
            String(localized: "Die Audiodatei konnte nicht weiter geschrieben werden (\(reason)). Alles bis zu diesem Zeitpunkt Aufgenommene ist gespeichert.")
        case .lowDiskSpace(let available):
            String(localized: "Auf dem Gerät sind nur noch \(TimeFormatting.byteCount(available)) frei. Die Aufnahme wurde beendet, bevor der Speicher voll ist; alles bisher Aufgenommene ist gespeichert.")
        }
        logger.error("Stopping the recording automatically: \(String(describing: event), privacy: .public)")
        let noteID = await stop()
        automaticallyStoppedNoteID = noteID
        notices?.post(UserNotice(title: String(localized: "Aufnahme beendet"), message: message, noteID: noteID))
    }

    private func handleInterruption(_ interruption: AudioSessionController.Interruption) {
        guard phase == .recording || phase == .paused else { return }
        switch interruption {
        case .began:
            pause(because: String(localized: "Die Aufnahme wurde vom System unterbrochen, z. B. durch einen Anruf."))
        case .ended(let shouldResume):
            if shouldResume, phase == .paused {
                togglePause()
            }
        }
    }

    private func pause(because message: String) {
        if phase == .recording {
            recorder.pause()
            phase = .paused
        }
        interruptionMessage = message
        liveActivity.update(isPaused: true, elapsed: recorder.recordedTime)
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

    // MARK: - System activity and sleep (macOS)

    private func beginSystemActivity() {
        #if os(macOS)
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Aufnahme läuft"
        )
        #endif
    }

    private func endSystemActivity() {
        #if os(macOS)
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
        #endif
    }

    /// Closing the lid or choosing "Ruhezustand" still puts the Mac to sleep. The audio
    /// devices stop, so the recording pauses at a defined position instead of silently
    /// recording nothing; after waking, the user resumes it.
    private func observeSystemSleep() {
        #if os(macOS)
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.phase == .recording else { return }
                    self.logger.info("The Mac goes to sleep, pausing the recording")
                    self.pause(because: String(localized: "Die Aufnahme wurde pausiert, weil der Mac in den Ruhezustand gewechselt ist. Setze sie fort, sobald das Gespräch weitergeht."))
                }
            },
        ]
        #endif
    }
}
