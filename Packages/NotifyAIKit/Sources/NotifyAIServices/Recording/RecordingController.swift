//
//  RecordingController.swift
//  NotifyAIServices
//

import AudioCapture
import Foundation
import NotifyAICore
import NotifyAIPersistence
import Observation
import OSLog

/// Drives a recording session: start, pause, markers, interruptions and stop.
///
/// The details live in collaborators: an `AudioRecording` captures, `RecordingMeter` holds
/// the levels and time, `LiveTranscriptFeed` the live transcript, `RecordingNoteWriter`
/// creates and completes the note. Everything that touches hardware or the system is passed
/// in as a protocol (`RecordingPorts.swift`), so the state machine is tested with fakes. One
/// instance exists per app; the main window, the macOS menu bar and the Live Activity all
/// show its state.
///
/// This controller is the single owner of the recording's state. Collaborators never
/// pause or stop on their own; they report (`CaptureEvent`) and the controller decides, so
/// what the UI shows always matches what is recorded. It reports typed values
/// (`RecordingPauseReason`, `RecordingEvent`); the app turns them into text.
///
/// Robustness:
/// - A write error or an almost full disk stops the recording; what was recorded is kept
///   and `events` reports why (`.stoppedAutomatically`).
/// - A device that fails and cannot be restarted (`CaptureEvent.inputFailed`) pauses the
///   recording with a reason; resuming retries the device.
/// - A system interruption (phone call) pauses the recording and resumes it afterwards,
///   but only if the interruption paused it. A pause the user chose is never lifted.
/// - On the Mac, App Nap and idle sleep are suspended while recording. When the Mac goes
///   to sleep anyway (lid closed), the recording pauses and says so.
/// - Live transcription that falls too far behind is abandoned; the file is transcribed
///   after the recording.
@MainActor
@Observable
public final class RecordingController {
    /// After this much recorded time without any system audio, the UI suggests checking the permission.
    public static let systemAudioHintDelay = 10

    public var draft = Draft()
    public private(set) var phase: Phase = .idle
    /// Source of the running recording.
    public private(set) var audioSource: RecordingAudioSource = .microphone
    /// The app whose audio is recorded, for display.
    public private(set) var systemAudioTarget: SystemAudioTarget = .allApps
    public private(set) var markers: [Marker] = []
    /// Set briefly after a marker was added, for visual feedback.
    public private(set) var lastMarker: Marker?
    /// Why starting or resuming failed; shown until `dismissError()`.
    public private(set) var errorMessage: String?
    /// Why the recording is paused without the user having paused it.
    public private(set) var pauseReason: RecordingPauseReason?
    /// The note of a recording that stopped on its own (full disk, write error). The
    /// recording screen closes and opens the note.
    public private(set) var automaticallyStoppedNoteID: UUID?

    public let meter = RecordingMeter()
    public let transcript = LiveTranscriptFeed()
    /// Automatic stops, for the app's notices.
    @ObservationIgnored public let events = EventChannel<RecordingEvent>()

    public var isActive: Bool { phase != .idle }
    public var canStart: Bool { phase == .idle && draft.consentConfirmed }

    /// No system audio arrived yet: either nothing is playing, or macOS denied the permission.
    public var isMissingSystemAudio: Bool {
        audioSource.usesSystemAudio && isActive && !meter.hasReceivedSystemAudio && meter.elapsedSeconds >= Self.systemAudioHintDelay
    }

    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let transcription: TranscriptionService
    @ObservationIgnored private let processing: ProcessingCoordinator
    @ObservationIgnored private let audioSession: AudioSessionController
    @ObservationIgnored private let recorder: any AudioRecording
    @ObservationIgnored private let microphone: any MicrophoneAccess
    @ObservationIgnored private let system: any SystemActivityControlling
    @ObservationIgnored private let liveActivity: (any RecordingActivityPresenting)?
    @ObservationIgnored private let noteWriter: RecordingNoteWriter
    /// Condenses finished chapters of long recordings while recording; `nil` disables it.
    @ObservationIgnored private let liveChapters: LiveChapterSummarizer?
    @ObservationIgnored private var noteID: UUID?
    /// Delivers the recorder's streams; they end when the recorder stops.
    @ObservationIgnored private var captureStreams: CaptureStreamConsumer?
    @ObservationIgnored private var lastMarkerReset: Task<Void, Never>?
    /// Decides whether the end of an interruption may resume the recording.
    @ObservationIgnored private var interruptions = InterruptionPolicy()
    /// A resume is waiting for the devices to restart; further toggles are ignored.
    @ObservationIgnored private var isResuming = false
    @ObservationIgnored private var subscriptions: [EventSubscription] = []
    @ObservationIgnored private let logger = Logger.audio

    init(
        store: NoteStore,
        settings: AppSettings,
        transcription: TranscriptionService,
        processing: ProcessingCoordinator,
        audioSession: AudioSessionController,
        devices: Devices,
        liveChapters: LiveChapterSummarizer? = nil
    ) {
        self.store = store
        self.settings = settings
        self.transcription = transcription
        self.processing = processing
        self.audioSession = audioSession
        self.recorder = devices.recorder
        self.microphone = devices.microphone
        self.system = devices.system
        self.liveActivity = devices.activity
        self.liveChapters = liveChapters
        noteWriter = RecordingNoteWriter(store: store)

        audioSession.interruptions.subscribe { [weak self] interruption in
            self?.handleInterruption(interruption)
        }.store(in: &subscriptions)
        transcript.events.subscribe { [weak self] event in
            switch event {
            case .segmentsChanged(let segments):
                self?.liveChapters?.transcriptDidChange(segments)
            case .fellBehind:
                // Nobody consumes the audio stream any more; stop filling it.
                self?.recorder.stopStreamingAudio()
            }
        }.store(in: &subscriptions)
        // Closing the lid or choosing "Ruhezustand" still puts the Mac to sleep. The audio
        // devices stop, so the recording pauses at a defined position instead of silently
        // recording nothing; after waking, the user resumes it.
        system.willSleep.subscribe { [weak self] in
            guard let self, phase == .recording else { return }
            logger.info("The system goes to sleep, pausing the recording")
            pause(because: .systemSleep)
        }.store(in: &subscriptions)
    }

    // MARK: - Session lifecycle

    public func start() async {
        guard canStart else { return }
        errorMessage = nil
        pauseReason = nil
        automaticallyStoppedNoteID = nil
        phase = .starting

        let configuration = settings.recording.captureConfiguration
        if configuration.source.usesMicrophone, !(await microphone.requestAccess()) {
            phase = .idle
            errorMessage = RecordingError.microphoneAccessDenied.localizedDescription
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
            recorder.setReducedLevelUpdates(!meter.showsLevels)
            markers = []
            lastMarker = nil
            phase = .recording
            interruptions = InterruptionPolicy()
            system.beginRecordingActivity()
            liveActivity?.start(title: note.title)
            // With live transcription the recording needs the Neural Engine now: a running
            // job stops and continues from its last saved step afterwards.
            processing.pauseForRecording(interruptingRunningJob: settings.transcription.liveTranscription)
            captureStreams = CaptureStreamConsumer(streams, meter: meter, transcript: transcript) { [weak self] event in
                self?.handle(event)
            }
            startLiveTranscription(for: note)
        } catch {
            logger.error("Starting the recording failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
            store.deleteReportingErrors(note)
            audioSession.deactivate()
            phase = .idle
        }
    }

    /// Pauses or resumes at the user's request. Resuming waits until the devices run again;
    /// if they cannot be started, the recording stays paused and says why.
    public func togglePause() async {
        switch phase {
        case .recording:
            // A pause the user chose is not lifted by the end of an interruption.
            interruptions.userTookOver()
            recorder.pause()
            phase = .paused
            liveActivity?.update(isPaused: true, elapsed: recorder.recordedTime)
        case .paused:
            interruptions.userTookOver()
            await resume()
        default:
            return
        }
    }

    private func resume() async {
        guard phase == .paused, !isResuming, let noteID else { return }
        isResuming = true
        defer { isResuming = false }
        do {
            try await recorder.resume()
            // The recording may have been stopped or discarded while the devices restarted.
            guard phase == .paused, self.noteID == noteID else { return }
            pauseReason = nil
            phase = .recording
        } catch {
            guard phase == .paused, self.noteID == noteID else { return }
            logger.error("Resuming the recording failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
        liveActivity?.update(isPaused: phase == .paused, elapsed: recorder.recordedTime)
    }

    /// Flags the current moment as important. The transcript later highlights
    /// `Marker.highlightPadding` seconds before and after it.
    public func addMarker() {
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
    public func stop() async -> UUID? {
        guard phase == .recording || phase == .paused, let noteID else { return nil }
        phase = .finishing
        let result = await recorder.stop()
        captureStreams?.stopEvents()
        // Chapters condensed so far stay in the digest store; the rest is done by the processing.
        endSystemSession()

        // The recorder finished its streams; wait until all audio reached the live session.
        await captureStreams?.waitForAudio()
        let finalTranscript = await transcript.finish()
        await noteWriter.complete(
            noteID: noteID,
            result: result,
            markers: markers,
            transcript: finalTranscript,
            engine: transcript.engineKind
        )

        reset()
        processing.resumeAfterRecording()
        processing.enqueue(.process(noteID))
        return noteID
    }

    /// Stops and deletes the recording.
    public func discard() async {
        guard isActive, let noteID else { return }
        await recorder.stop()
        captureStreams?.cancel()
        // Digests of this recording are removed together with the note (`NoteStoreEvent.deleted`).
        endSystemSession()
        await transcript.cancel()
        if let note = store.note(id: noteID) {
            store.deleteReportingErrors(note)
        }
        reset()
        processing.resumeAfterRecording()
    }

    public func dismissError() {
        errorMessage = nil
    }

    /// Called by the recording screen after it reacted to an automatic stop.
    public func acknowledgeAutomaticStop() {
        automaticallyStoppedNoteID = nil
    }

    // MARK: - Meters

    /// Level meters register while they are on screen. Without any, levels are published
    /// only once per second (for the elapsed time) instead of ten times.
    public func setMeterVisible(_ visible: Bool, id: String) {
        meter.setVisible(visible, id: id)
        recorder.setReducedLevelUpdates(!meter.showsLevels)
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

    /// Releases what the session held outside the app: the audio session, the Live
    /// Activity, the system activity and the live chapter summaries.
    private func endSystemSession() {
        audioSession.deactivate()
        liveActivity?.end()
        system.endRecordingActivity()
        liveChapters?.stop()
    }

    private func handle(_ event: CaptureEvent) {
        switch event {
        case .inputFailed(let reason):
            inputDidFail(reason: reason)
        case .writeFailed(let reason):
            scheduleAutomaticStop(because: .writeFailed(reason))
        case .lowDiskSpace(let available):
            scheduleAutomaticStop(because: .lowDiskSpace(availableBytes: available))
        }
    }

    /// A device stopped delivering and could not be restarted. Nothing is recorded any
    /// more, so the recording pauses visibly instead of appearing to run.
    private func inputDidFail(reason: String) {
        guard phase == .recording || phase == .paused else { return }
        logger.error("Audio input failed: \(reason, privacy: .public)")
        // The end of an interruption must not try to resume a failed device on its own.
        interruptions.userTookOver()
        pause(because: .deviceUnavailable(reason))
    }

    /// The capture cannot continue: stop and keep what was recorded. The stop runs in its
    /// own task, because stopping cancels the task that delivers the events.
    private func scheduleAutomaticStop(because reason: AutomaticStopReason) {
        Task { await stopAutomatically(because: reason) }
    }

    private func stopAutomatically(because reason: AutomaticStopReason) async {
        guard phase == .recording || phase == .paused else { return }
        logger.error("Stopping the recording automatically: \(String(describing: reason), privacy: .public)")
        let noteID = await stop()
        automaticallyStoppedNoteID = noteID
        events.send(.stoppedAutomatically(noteID: noteID, reason: reason))
    }

    private func handleInterruption(_ interruption: AudioSessionController.Interruption) {
        let action = switch interruption {
        case .began:
            interruptions.interruptionBegan(isRecording: phase == .recording)
        case .ended(let shouldResume):
            interruptions.interruptionEnded(shouldResume: shouldResume, isPaused: phase == .paused)
        }
        switch action {
        case .none:
            break
        case .pause:
            pause(because: .systemInterruption)
        case .resume:
            Task { await resume() }
        }
    }

    private func pause(because reason: RecordingPauseReason) {
        if phase == .recording {
            recorder.pause()
            phase = .paused
        }
        pauseReason = reason
        liveActivity?.update(isPaused: true, elapsed: recorder.recordedTime)
    }

    private func reset() {
        meter.reset()
        transcript.reset()
        noteID = nil
        captureStreams = nil
        markers = []
        lastMarker = nil
        pauseReason = nil
        interruptions = InterruptionPolicy()
        audioSource = .microphone
        systemAudioTarget = .allApps
        draft = Draft()
        phase = .idle
    }
}
