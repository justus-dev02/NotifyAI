//
//  WhisperEngine.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore
import OSLog
import Synchronization
@preconcurrency import WhisperKit

/// Transcription with Whisper via WhisperKit.
///
/// Models are only ever loaded from the local model directory (`download: false`), so
/// transcription works offline once a model has been downloaded in the settings.
///
/// A loaded model takes several hundred megabytes. It is released two minutes after the last
/// transcription and immediately when the system reports memory pressure, unless it is in use.
final class WhisperEngine: TranscriptionEngine, WhisperModelUsage {
    let kind = TranscriptionEngineKind.whisper
    private let runtime: WhisperRuntime
    private let memoryPressure: any DispatchSourceMemoryPressure

    init(modelStore: WhisperModelStore) {
        let runtime = WhisperRuntime(modelStore: modelStore)
        self.runtime = runtime
        memoryPressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        memoryPressure.setEventHandler {
            Task { await runtime.unloadIfIdle(reason: "memory pressure") }
        }
        memoryPressure.activate()
    }

    deinit {
        memoryPressure.cancel()
    }

    func startLiveSession(options: TranscriptionOptions) async throws -> any LiveTranscriptionSession {
        // Load the model up front so that a missing model is reported before recording
        // instead of silently producing no text.
        try await runtime.prepare(options.whisperModel)
        return WhisperLiveSession(runtime: runtime, options: options)
    }

    func transcribeFile(
        at url: URL,
        options: TranscriptionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        let segments = try await runtime.transcribeFile(at: url, options: options, progress: progress)
        return Transcript.normalized(segments)
    }

    /// Releases the loaded model, e.g. after it was deleted.
    func unloadModel() async {
        await runtime.unload()
    }

    /// Whether a transcription is using the model right now; deleting it must wait.
    var isInUse: Bool {
        get async { await runtime.isInUse }
    }
}

// MARK: - Runtime

/// Owns the WhisperKit pipeline. As an actor it serializes access to the (non-thread-safe)
/// pipeline, so live transcription and file transcription never run concurrently.
///
/// Users of the model bracket their work with `beginUse()` / `endUse()`. When the last use
/// ends, the model is unloaded after `idleUnloadDelay`; memory pressure unloads it at once.
/// A model in use is never unloaded, because WhisperKit would crash mid-transcription.
actor WhisperRuntime {
    static let idleUnloadDelay: Duration = .seconds(120)

    private let modelStore: WhisperModelStore
    private let idleDelay: Duration
    private var pipeline: WhisperKit?
    private var loadedModelID: String?
    private var activeUses = 0
    private var idleUnload: Task<Void, Never>?

    init(modelStore: WhisperModelStore, idleDelay: Duration = WhisperRuntime.idleUnloadDelay) {
        self.modelStore = modelStore
        self.idleDelay = idleDelay
    }

    var isInUse: Bool { activeUses > 0 }
    var isLoaded: Bool { pipeline != nil }

    /// Loads the model ahead of a live session. The session's own use keeps it loaded.
    func prepare(_ model: WhisperModel) async throws {
        beginUse()
        defer { endUse() }
        _ = try await pipeline(for: model)
    }

    func beginUse() {
        activeUses += 1
        idleUnload?.cancel()
        idleUnload = nil
    }

    func endUse() {
        activeUses = max(0, activeUses - 1)
        scheduleIdleUnload()
    }

    /// Unloads the model unless it is in use.
    func unloadIfIdle(reason: String) async {
        guard activeUses == 0, pipeline != nil else { return }
        Logger.transcription.info("Unloading the Whisper model (\(reason, privacy: .public))")
        await unload()
    }

    func unload() async {
        idleUnload?.cancel()
        idleUnload = nil
        await pipeline?.unloadModels()
        pipeline = nil
        loadedModelID = nil
    }

    private func scheduleIdleUnload() {
        guard activeUses == 0, pipeline != nil else { return }
        idleUnload?.cancel()
        let delay = idleDelay
        idleUnload = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle(reason: "idle")
        }
    }

    /// Transcribes a chunk of the live recording.
    func transcribe(_ chunk: NotifyAICore.AudioChunk, options: TranscriptionOptions) async throws -> [TranscriptSegment] {
        let interval = Signposts.transcription.beginInterval("Whisper chunk", "\(chunk.duration, format: .fixed(precision: 1)) s")
        defer { Signposts.transcription.endInterval("Whisper chunk", interval) }
        let pipeline = try await pipeline(for: options.whisperModel)
        let results = try await pipeline.transcribe(
            audioArray: chunk.samples,
            decodeOptions: Self.decodingOptions(language: options.language, chunking: false)
        )
        return Self.segments(from: results, offset: chunk.startTime)
    }

    func transcribeFile(
        at url: URL,
        options: TranscriptionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        beginUse()
        defer { endUse() }
        let pipeline = try await pipeline(for: options.whisperModel)
        let fractionCompleted = pipeline.progress
        let results = try await pipeline.transcribe(
            audioPath: url.path(percentEncoded: false),
            decodeOptions: Self.decodingOptions(language: options.language, chunking: true)
        ) { _ in
            progress(fractionCompleted.fractionCompleted)
            // Returning `false` stops decoding early.
            return Task.isCancelled ? false : nil
        }
        try Task.checkCancellation()
        return Self.segments(from: results, offset: 0)
    }

    private func pipeline(for model: WhisperModel) async throws -> WhisperKit {
        if let pipeline, loadedModelID == model.id {
            return pipeline
        }
        guard modelStore.isInstalled(model), let folder = modelStore.folder(for: model) else {
            throw TranscriptionError.whisperModelNotInstalled(model.name)
        }
        await unload()

        let configuration = WhisperKitConfig(
            downloadBase: modelStore.downloadBase,
            modelFolder: folder.path(percentEncoded: false),
            tokenizerFolder: modelStore.downloadBase,
            computeOptions: ModelComputeOptions(
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            ),
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )
        Logger.transcription.info("Loading Whisper model \(model.id, privacy: .public)")
        let pipeline = try await WhisperKit(configuration)
        self.pipeline = pipeline
        loadedModelID = model.id
        return pipeline
    }

    /// Explicit language and task: without them WhisperKit falls back to English for the
    /// prefill prompt and translates German speech. Special tokens are removed from the text.
    private static func decodingOptions(language: TranscriptionLanguage, chunking: Bool) -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language.languageCode,
            temperature: 0,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: true,
            chunkingStrategy: chunking ? .vad : ChunkingStrategy.none
        )
    }

    /// Converts WhisperKit results into segments on the recording timeline.
    static func segments(from results: [TranscriptionResult], offset: TimeInterval) -> [TranscriptSegment] {
        results.flatMap(\.segments).compactMap { segment in
            // Standard Whisper heuristic against hallucinations on non-speech audio.
            if segment.noSpeechProb > 0.6, segment.avgLogprob < -1 {
                return nil
            }
            let words = (segment.words ?? []).map {
                TranscriptWord(text: $0.word, start: offset + Double($0.start), end: offset + Double($0.end))
            }
            let text = words.isEmpty ? segment.text : words.map(\.text).joined()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return TranscriptSegment(
                start: offset + Double(segment.start),
                end: offset + Double(segment.end),
                text: trimmed,
                words: words
            )
        }
    }
}

// MARK: - Live session

/// Cuts the live audio into phrase-sized chunks and transcribes them one after another.
///
/// Each chunk is transcribed exactly once, so the work grows linearly with the recording.
/// If transcription falls behind, chunks queue up; the session reports how much audio is
/// waiting (`.backlog`), so the feed can give up on live transcription before the queue
/// grows without bound. Whatever is queued is completed in `finish()`.
private actor WhisperLiveSession: LiveTranscriptionSession {
    nonisolated let events: AsyncStream<LiveTranscriptionEvent>

    private let eventContinuation: AsyncStream<LiveTranscriptionEvent>.Continuation
    private let chunkContinuation: AsyncStream<NotifyAICore.AudioChunk>.Continuation
    private let worker: Task<[TranscriptSegment], any Error>
    /// Seconds of audio handed to the worker and not transcribed yet.
    private let queue: QueuedAudio
    private var chunker = SpeechChunker()
    private var isFinished = false

    init(runtime: WhisperRuntime, options: TranscriptionOptions) {
        let (events, eventContinuation) = AsyncStream.makeStream(of: LiveTranscriptionEvent.self)
        let (chunks, chunkContinuation) = AsyncStream.makeStream(of: NotifyAICore.AudioChunk.self)
        let queue = QueuedAudio()
        self.events = events
        self.eventContinuation = eventContinuation
        self.chunkContinuation = chunkContinuation
        self.queue = queue
        self.worker = Task {
            await runtime.beginUse()
            defer { Task { await runtime.endUse() } }
            var transcript: [TranscriptSegment] = []
            for await chunk in chunks {
                try Task.checkCancellation()
                let segments = try await runtime.transcribe(chunk, options: options)
                transcript.append(contentsOf: segments)
                if !segments.isEmpty {
                    eventContinuation.yield(.finalized(segments))
                }
                let remaining = queue.remove(chunk.duration)
                eventContinuation.yield(.backlog(remaining))
            }
            return transcript
        }
    }

    func append(_ chunk: NotifyAICore.AudioChunk) {
        guard !isFinished else { return }
        for completed in chunker.append(chunk) {
            chunkContinuation.yield(completed)
            let queued = queue.add(completed.duration)
            eventContinuation.yield(.backlog(queued))
        }
    }

    func finish() async throws -> [TranscriptSegment] {
        guard !isFinished else { return try await worker.value }
        isFinished = true
        if let tail = chunker.flush() {
            chunkContinuation.yield(tail)
        }
        chunkContinuation.finish()
        defer { eventContinuation.finish() }
        return Transcript.normalized(try await worker.value)
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        chunkContinuation.finish()
        worker.cancel()
        eventContinuation.finish()
    }
}

/// Seconds of audio waiting for the Whisper worker; shared by the session and its worker.
private final class QueuedAudio: Sendable {
    private let seconds = Mutex<TimeInterval>(0)

    func add(_ duration: TimeInterval) -> TimeInterval {
        seconds.withLock { seconds in
            seconds += duration
            return seconds
        }
    }

    func remove(_ duration: TimeInterval) -> TimeInterval {
        seconds.withLock { seconds in
            seconds = max(0, seconds - duration)
            return seconds
        }
    }
}
