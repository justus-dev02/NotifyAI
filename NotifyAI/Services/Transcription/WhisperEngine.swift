//
//  WhisperEngine.swift
//  NotifyAI
//

import Foundation
import OSLog
@preconcurrency import WhisperKit

/// Transcription with Whisper via WhisperKit.
///
/// Models are only ever loaded from the local model directory (`download: false`), so
/// transcription works offline once a model has been downloaded in the settings.
final class WhisperEngine: TranscriptionEngine {
    let kind = TranscriptionEngineKind.whisper
    private let runtime: WhisperRuntime

    init(modelStore: WhisperModelStore) {
        runtime = WhisperRuntime(modelStore: modelStore)
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
}

// MARK: - Runtime

/// Owns the WhisperKit pipeline. As an actor it serializes access to the (non-thread-safe)
/// pipeline, so live transcription and file transcription never run concurrently.
actor WhisperRuntime {
    private let modelStore: WhisperModelStore
    private var pipeline: WhisperKit?
    private var loadedModelID: String?

    init(modelStore: WhisperModelStore) {
        self.modelStore = modelStore
    }

    func prepare(_ model: WhisperModel) async throws {
        _ = try await pipeline(for: model)
    }

    func unload() async {
        await pipeline?.unloadModels()
        pipeline = nil
        loadedModelID = nil
    }

    /// Transcribes a chunk of the live recording.
    func transcribe(_ chunk: AudioChunk, options: TranscriptionOptions) async throws -> [TranscriptSegment] {
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
/// If transcription falls behind, chunks queue up and are completed in `finish()`.
private actor WhisperLiveSession: LiveTranscriptionSession {
    nonisolated let events: AsyncStream<LiveTranscriptionEvent>

    private let eventContinuation: AsyncStream<LiveTranscriptionEvent>.Continuation
    private let chunkContinuation: AsyncStream<AudioChunk>.Continuation
    private let worker: Task<[TranscriptSegment], any Error>
    private var chunker = SpeechChunker()
    private var isFinished = false

    init(runtime: WhisperRuntime, options: TranscriptionOptions) {
        let (events, eventContinuation) = AsyncStream.makeStream(of: LiveTranscriptionEvent.self)
        let (chunks, chunkContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
        self.events = events
        self.eventContinuation = eventContinuation
        self.chunkContinuation = chunkContinuation
        self.worker = Task {
            var transcript: [TranscriptSegment] = []
            for await chunk in chunks {
                try Task.checkCancellation()
                let segments = try await runtime.transcribe(chunk, options: options)
                transcript.append(contentsOf: segments)
                if !segments.isEmpty {
                    eventContinuation.yield(.finalized(segments))
                }
            }
            return transcript
        }
    }

    func append(_ chunk: AudioChunk) {
        guard !isFinished else { return }
        for completed in chunker.append(chunk) {
            chunkContinuation.yield(completed)
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
