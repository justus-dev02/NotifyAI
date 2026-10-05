//
//  LiveTranscriptFeed.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore
import Observation
import OSLog

/// The live transcript of the running recording.
///
/// Starts a live session of the chosen engine, forwards the recorded audio and collects the
/// finalized segments plus the current hypothesis. Audio that arrives while the model is
/// still loading is buffered and replayed in order, so the transcript is complete from the
/// first second.
///
/// Live transcription may not fall behind by more than `maximumBacklog`: audio waiting for
/// the model to load plus audio the session has not transcribed yet (e.g. Whisper on a slow
/// Mac). Beyond that the feed gives up (`.fellBehind`), frees the queued audio and the note
/// is transcribed from the file after the recording, so memory cannot grow without bound.
@MainActor
@Observable
public final class LiveTranscriptFeed {
    public enum State: Equatable {
        case off
        case preparing
        case running
        case unavailable(String)
        /// Transcription could not keep up; the file is transcribed after the recording.
        case fellBehind
    }

    /// What listeners (the recording controller, live chapter summaries) react to.
    enum Event {
        /// New finalized segments arrived; carries all finalized segments so far.
        case segmentsChanged([TranscriptSegment])
        /// Live transcription gave up because it fell too far behind.
        case fellBehind
    }

    /// How far live transcription may lag behind the recording.
    static let maximumBacklog: TimeInterval = 60

    public private(set) var state: State = .off
    public private(set) var segments: [TranscriptSegment] = []
    /// The current hypothesis, replaced until it is finalized.
    public private(set) var volatileText = ""
    public private(set) var engineKind: TranscriptionEngineKind = .appleSpeech

    @ObservationIgnored let events = EventChannel<Event>()

    @ObservationIgnored private var session: (any LiveTranscriptionSession)?
    @ObservationIgnored private var setupTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var pendingChunks: [AudioChunk] = []
    /// Seconds of audio in `pendingChunks`.
    @ObservationIgnored private var pendingDuration: TimeInterval = 0
    /// Seconds of audio the session reported as not transcribed yet.
    @ObservationIgnored private var sessionBacklog: TimeInterval = 0
    @ObservationIgnored private let maximumBacklog: TimeInterval
    /// Identifies the current session; a model that finishes loading after a stop is discarded.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let logger = Logger.transcription

    init(maximumBacklog: TimeInterval = LiveTranscriptFeed.maximumBacklog) {
        self.maximumBacklog = maximumBacklog
    }

    /// The seconds live transcription currently lags behind the recording.
    var backlog: TimeInterval { pendingDuration + sessionBacklog }

    func start(engine: any TranscriptionEngine, kind: TranscriptionEngineKind, options: TranscriptionOptions) {
        reset()
        generation += 1
        let startedGeneration = generation
        engineKind = kind
        state = .preparing
        setupTask = Task { [weak self] in
            do {
                let session = try await engine.startLiveSession(options: options)
                guard let self, !Task.isCancelled, self.generation == startedGeneration else {
                    await session.cancel()
                    return
                }
                await self.activate(session)
            } catch {
                guard let self, self.generation == startedGeneration else { return }
                self.state = .unavailable(error.localizedDescription)
                self.pendingChunks.removeAll()
                self.pendingDuration = 0
            }
        }
    }

    /// Passes recorded audio on, or buffers it while the model is loading.
    func append(_ chunk: AudioChunk) async {
        if let session {
            await session.append(chunk)
        } else if state == .preparing {
            pendingChunks.append(chunk)
            pendingDuration += chunk.duration
            checkBacklog()
        }
    }

    /// Finishes the session and returns the final transcript. A session that is still
    /// loading or fell behind is abandoned; the file is transcribed after the recording.
    func finish() async -> [TranscriptSegment] {
        setupTask?.cancel()
        generation += 1
        guard let session, state == .running else { return [] }
        do {
            let transcript = try await session.finish()
            await eventTask?.value
            return transcript
        } catch {
            logger.error("Finishing live transcription failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func cancel() async {
        setupTask?.cancel()
        generation += 1
        await session?.cancel()
    }

    func reset() {
        setupTask?.cancel()
        eventTask?.cancel()
        session = nil
        setupTask = nil
        eventTask = nil
        pendingChunks = []
        pendingDuration = 0
        sessionBacklog = 0
        segments = []
        volatileText = ""
        state = .off
    }

    // MARK: - Private

    private func activate(_ session: any LiveTranscriptionSession) async {
        // Replay buffered audio in order before new chunks are forwarded directly. Chunks
        // that arrive during the replay are appended to the buffer and replayed too.
        let activatedGeneration = generation
        while !pendingChunks.isEmpty {
            let chunk = pendingChunks.removeFirst()
            pendingDuration = max(0, pendingDuration - chunk.duration)
            await session.append(chunk)
        }
        guard generation == activatedGeneration else {
            // Stopped or fell behind during the replay.
            await session.cancel()
            return
        }
        self.session = session
        state = .running
        eventTask = Task { [weak self] in
            for await event in session.events {
                self?.apply(event)
            }
        }
    }

    private func apply(_ event: LiveTranscriptionEvent) {
        switch event {
        case .finalized(let newSegments):
            segments.append(contentsOf: newSegments)
            events.send(.segmentsChanged(segments))
        case .volatile(let text):
            volatileText = text
        case .backlog(let seconds):
            sessionBacklog = seconds
            checkBacklog()
        }
    }

    private func checkBacklog() {
        guard state == .preparing || state == .running, backlog > maximumBacklog else { return }
        logger.error("Live transcription is \(self.backlog, format: .fixed(precision: 0), privacy: .public) s behind; transcribing the file afterwards instead")
        setupTask?.cancel()
        eventTask?.cancel()
        generation += 1
        let abandoned = session
        session = nil
        pendingChunks = []
        pendingDuration = 0
        sessionBacklog = 0
        volatileText = ""
        state = .fellBehind
        if let abandoned {
            Task { await abandoned.cancel() }
        }
        events.send(.fellBehind)
    }
}
