//
//  RecordingController.swift
//  NotifyAI
//

import Foundation
import Observation
import OSLog

/// Drives a recording session: microphone capture, live transcription and markers.
///
/// One instance exists per app. The main window and the macOS menu bar panel both
/// observe it, so they always show the same state.
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

    enum LiveTranscriptionState: Equatable {
        case off
        case preparing
        case running
        case unavailable(String)
    }

    /// What the user entered before starting.
    struct Draft {
        var title = ""
        var focus: RecordingFocus = .general
        var participants = ""
        var consentConfirmed = false
    }

    static let levelHistoryLength = 48
    /// After this much recorded time without any system audio, the UI suggests checking the permission.
    static let systemAudioHintDelay: TimeInterval = 10

    var draft = Draft()
    private(set) var phase: Phase = .idle
    private(set) var elapsed: TimeInterval = 0
    /// Recent microphone levels (0…1), oldest first.
    private(set) var levels = [Float](repeating: 0, count: levelHistoryLength)
    /// Recent system audio levels while it is recorded together with the microphone.
    private(set) var systemLevels = [Float](repeating: 0, count: levelHistoryLength)
    /// Source of the running recording.
    private(set) var audioSource: RecordingAudioSource = .microphone
    /// The app whose audio is recorded, for display.
    private(set) var systemAudioTarget: SystemAudioTarget = .allApps
    private(set) var hasReceivedSystemAudio = false
    private(set) var liveSegments: [TranscriptSegment] = []
    private(set) var volatileText = ""
    private(set) var liveTranscription: LiveTranscriptionState = .off
    private(set) var markers: [Marker] = []
    /// Set briefly after a marker was added, for visual feedback.
    private(set) var lastMarker: Marker?
    private(set) var errorMessage: String?
    private(set) var interruptionMessage: String?
    private(set) var engineKind: TranscriptionEngineKind = .appleSpeech

    var isActive: Bool { phase != .idle }

    /// No system audio arrived yet: either nothing is playing, or macOS denied the permission.
    var isMissingSystemAudio: Bool {
        audioSource.usesSystemAudio && isActive && !hasReceivedSystemAudio && elapsed >= Self.systemAudioHintDelay
    }
    var canStart: Bool { phase == .idle && draft.consentConfirmed }

    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let transcription: TranscriptionService
    @ObservationIgnored private let processing: ProcessingCoordinator
    @ObservationIgnored private let audioSession: AudioSessionController
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let liveActivity = RecordingLiveActivity()
    @ObservationIgnored private var noteID: UUID?
    @ObservationIgnored private var liveSession: (any LiveTranscriptionSession)?
    /// Consume the recorder's level and chunk streams; they end when the recorder stops.
    @ObservationIgnored private var captureTasks: [Task<Void, Never>] = []
    /// Applies live transcription events; ends when the live session finishes.
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var liveSetupTask: Task<Void, Never>?
    @ObservationIgnored private var pendingChunks: [AudioChunk] = []
    @ObservationIgnored private var lastMarkerReset: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger.audio

    init(
        store: NoteStore,
        settings: AppSettings,
        transcription: TranscriptionService,
        processing: ProcessingCoordinator,
        audioSession: AudioSessionController
    ) {
        self.store = store
        self.settings = settings
        self.transcription = transcription
        self.processing = processing
        self.audioSession = audioSession
        audioSession.onInterruption = { [weak self] interruption in
            self?.handleInterruption(interruption)
        }
    }

    // MARK: - Session lifecycle

    func start() async {
        guard canStart else { return }
        errorMessage = nil
        interruptionMessage = nil
        phase = .starting

        let configuration = settings.captureConfiguration
        if configuration.source.usesMicrophone {
            guard await MicrophonePermission.request() else {
                phase = .idle
                errorMessage = "Kein Zugriff auf das Mikrofon. Bitte erlaube den Zugriff in den Systemeinstellungen."
                return
            }
        }

        let note = makeNote(configuration: configuration)
        do {
            try store.insert(note)
            try audioSession.activateForRecording()
            let url = store.locations.audioURL(fileName: NoteStore.recordingFileName(for: note.id))
            let streams = try await recorder.start(writingTo: url, configuration: configuration)
            noteID = note.id
            audioSource = configuration.source
            systemAudioTarget = configuration.systemAudioTarget
            engineKind = settings.engine
            resetLiveState()
            phase = .recording
            liveActivity.start(title: note.title)
            processing.isPaused = true
            consume(streams)
            if settings.liveTranscription {
                startLiveTranscription()
            } else {
                liveTranscription = .off
            }
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

        // The recorder finished its streams; wait until all audio reached the live session.
        for task in captureTasks { await task.value }
        // A session that is still loading is abandoned; the file is transcribed afterwards.
        liveSetupTask?.cancel()

        var liveTranscript: [TranscriptSegment] = []
        if let liveSession {
            do {
                liveTranscript = try await liveSession.finish()
                await eventTask?.value
            } catch {
                logger.error("Finishing live transcription failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // A title from the conversation right away; the summary refines it later.
        var keywords: [String] = []
        if !liveTranscript.isEmpty, draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let text = liveTranscript.map(\.text).joined(separator: " ")
            let languageCode = settings.language.languageCode
            keywords = await Task.detached(priority: .userInitiated) {
                TextAnalysis.keywords(in: text, languageCode: languageCode, limit: 2)
            }.value
        }

        if let note = store.note(id: noteID) {
            note.duration = result.duration
            note.markers = markers
            note.sourceActivity = result.sourceActivity
            note.status = .queued
            if !liveTranscript.isEmpty, let data = try? Transcript.encode(liveTranscript) {
                note.setTranscript(encoded: data, plainText: Transcript.plainText(of: liveTranscript), engine: engineKind)
            }
            if !note.isTitleUserDefined, !keywords.isEmpty {
                note.title = AutomaticTitle.make(keywords: keywords, date: note.createdAt)
            }
            try? store.save()
        }

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
        captureTasks.forEach { $0.cancel() }
        liveSetupTask?.cancel()
        await liveSession?.cancel()
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

    private func makeNote(configuration: CaptureConfiguration) -> Note {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let participants = draft.participants
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let id = UUID()
        let note = Note(
            id: id,
            title: title.isEmpty ? Note.automaticTitle(for: .recording) : title,
            isTitleUserDefined: !title.isEmpty,
            kind: .recording,
            status: .recording,
            focus: draft.focus,
            language: settings.language,
            participants: participants,
            consentConfirmedAt: .now,
            audioFileName: NoteStore.recordingFileName(for: id)
        )
        note.audioSource = configuration.source
        if configuration.source.usesSystemAudio, case .app(_, let name) = configuration.systemAudioTarget {
            note.sourceAppName = name
        }
        return note
    }

    private func consume(_ streams: AudioCaptureStreams) {
        captureTasks = [
            Task { [weak self] in
                for await level in streams.levels {
                    self?.record(level)
                }
            },
            Task { [weak self] in
                for await chunk in streams.chunks {
                    await self?.forward(chunk)
                }
            },
        ]
    }

    private func record(_ level: AudioLevel) {
        elapsed = level.recordedTime
        levels.removeFirst()
        levels.append(Self.meterValue(level.rms))
        if let systemRMS = level.systemRMS {
            systemLevels.removeFirst()
            systemLevels.append(Self.meterValue(systemRMS))
        }
        if level.hasReceivedSystemAudio, !hasReceivedSystemAudio {
            hasReceivedSystemAudio = true
        }
    }

    /// Perceptual scaling: speech RMS is typically 0.01–0.3.
    private static func meterValue(_ rms: Float) -> Float {
        min(1, max(0, (20 * log10(max(rms, 1e-4)) + 50) / 50))
    }

    /// Audio that arrives while the live session is still loading is buffered and sent
    /// once it is ready, so the live transcript is complete from the first second.
    private func forward(_ chunk: AudioChunk) async {
        if let liveSession {
            await liveSession.append(chunk)
        } else if liveTranscription == .preparing {
            pendingChunks.append(chunk)
        }
    }

    private func startLiveTranscription() {
        liveTranscription = .preparing
        let engine = transcription.engine(for: engineKind)
        let options = settings.transcriptionOptions
        let sessionNoteID = noteID
        liveSetupTask = Task { [weak self] in
            do {
                let session = try await engine.startLiveSession(options: options)
                // The recording may have been stopped while the model was loading.
                guard let self, !Task.isCancelled, self.noteID == sessionNoteID, self.phase != .finishing else {
                    await session.cancel()
                    return
                }
                await self.activate(session)
            } catch {
                guard let self, self.noteID == sessionNoteID else { return }
                self.liveTranscription = .unavailable(error.localizedDescription)
                self.pendingChunks.removeAll()
            }
        }
    }

    private func activate(_ session: any LiveTranscriptionSession) async {
        // Replay buffered audio in order before new chunks are forwarded directly.
        while !pendingChunks.isEmpty {
            let chunk = pendingChunks.removeFirst()
            await session.append(chunk)
        }
        liveSession = session
        liveTranscription = .running
        eventTask = Task { [weak self] in
            for await event in session.events {
                self?.apply(event)
            }
        }
    }

    private func apply(_ event: LiveTranscriptionEvent) {
        switch event {
        case .finalized(let segments):
            liveSegments.append(contentsOf: segments)
        case .volatile(let text):
            volatileText = text
        }
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

    private func resetLiveState() {
        elapsed = 0
        levels = [Float](repeating: 0, count: Self.levelHistoryLength)
        systemLevels = [Float](repeating: 0, count: Self.levelHistoryLength)
        hasReceivedSystemAudio = false
        liveSegments = []
        volatileText = ""
        markers = []
        lastMarker = nil
        pendingChunks = []
    }

    private func reset() {
        resetLiveState()
        noteID = nil
        liveSession = nil
        liveSetupTask = nil
        captureTasks = []
        eventTask = nil
        liveTranscription = .off
        interruptionMessage = nil
        audioSource = .microphone
        systemAudioTarget = .allApps
        draft = Draft()
        phase = .idle
    }
}
