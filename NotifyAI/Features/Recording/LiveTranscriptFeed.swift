//
//  LiveTranscriptFeed.swift
//  NotifyAI
//

import Foundation
import Observation
import OSLog

/// The live transcript of the running recording.
///
/// Starts a live session of the chosen engine, forwards the recorded audio and collects the
/// finalized segments plus the current hypothesis. Audio that arrives while the model is
/// still loading is buffered and replayed in order, so the transcript is complete from the
/// first second.
@MainActor
@Observable
final class LiveTranscriptFeed {
    enum State: Equatable {
        case off
        case preparing
        case running
        case unavailable(String)
    }

    private(set) var state: State = .off
    private(set) var segments: [TranscriptSegment] = []
    /// The current hypothesis, replaced until it is finalized.
    private(set) var volatileText = ""
    private(set) var engineKind: TranscriptionEngineKind = .appleSpeech

    /// Called with all finalized segments whenever new ones arrive.
    @ObservationIgnored var onSegmentsChanged: (([TranscriptSegment]) -> Void)?

    @ObservationIgnored private var session: (any LiveTranscriptionSession)?
    @ObservationIgnored private var setupTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var pendingChunks: [AudioChunk] = []
    /// Identifies the current session; a model that finishes loading after a stop is discarded.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let logger = Logger.transcription

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
            }
        }
    }

    /// Passes recorded audio on, or buffers it while the model is loading.
    func append(_ chunk: AudioChunk) async {
        if let session {
            await session.append(chunk)
        } else if state == .preparing {
            pendingChunks.append(chunk)
        }
    }

    /// Finishes the session and returns the final transcript. A session that is still
    /// loading is abandoned; the file is transcribed after the recording instead.
    func finish() async -> [TranscriptSegment] {
        setupTask?.cancel()
        generation += 1
        guard let session else { return [] }
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
        segments = []
        volatileText = ""
        state = .off
    }

    // MARK: - Private

    private func activate(_ session: any LiveTranscriptionSession) async {
        // Replay buffered audio in order before new chunks are forwarded directly.
        while !pendingChunks.isEmpty {
            let chunk = pendingChunks.removeFirst()
            await session.append(chunk)
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
            onSegmentsChanged?(segments)
        case .volatile(let text):
            volatileText = text
        }
    }
}
