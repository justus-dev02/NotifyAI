//
//  WhisperEngine.swift
//  NotifyAITranscription
//

import Foundation
import NotifyAICore
import NotifyAISupport
import OSLog
@preconcurrency import WhisperKit

/// Transcription with Whisper via WhisperKit.
///
/// Models are only ever loaded from the local model directory (`download: false`), so
/// transcription works offline once a model has been downloaded in the settings.
///
/// Live audio and files take the same path: `SpeechChunker` cuts phrase-sized chunks and
/// `SpeechDetector` lets only chunks with speech through. Whisper invents text for silence
/// and noise, so audio without speech never reaches it.
///
/// A loaded model takes several hundred megabytes. It is released two minutes after the last
/// transcription and immediately when the system reports memory pressure, unless it is in use.
package final class WhisperEngine: TranscriptionEngine, WhisperModelUsage {
    package let kind = TranscriptionEngineKind.whisper
    private let runtime: WhisperRuntime
    private let speechDetector: SpeechDetector
    private let memoryPressure: any DispatchSourceMemoryPressure

    package init(modelStore: WhisperModelStore, speechDetector: SpeechDetector = SpeechDetector()) {
        let runtime = WhisperRuntime(modelStore: modelStore)
        self.runtime = runtime
        self.speechDetector = speechDetector
        memoryPressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        memoryPressure.setEventHandler {
            Task { await runtime.unloadIfIdle(reason: "memory pressure") }
        }
        memoryPressure.activate()
    }

    deinit {
        memoryPressure.cancel()
    }

    package func startLiveSession(options: TranscriptionOptions) async throws -> any LiveTranscriptionSession {
        // Load the model up front so that a missing model is reported before recording
        // instead of silently producing no text.
        try await runtime.prepare(options.whisperModel)
        let runtime = runtime
        return ChunkedLiveSession(
            speechDetector: speechDetector,
            keepingModelLoaded: { work in
                await runtime.beginUse()
                defer { Task { await runtime.endUse() } }
                return try await work()
            },
            transcribe: { chunks in try await runtime.transcribe(chunks, options: options) }
        )
    }

    /// Reads the file block by block and transcribes it like a live recording. WhisperKit's
    /// own file chunking is not used: it only looks for cut points and transcribes silent
    /// stretches as well.
    package func transcribeFile(
        at url: URL,
        options: TranscriptionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        let runtime = runtime
        let speechDetector = speechDetector
        await runtime.beginUse()
        defer { Task { await runtime.endUse() } }
        // Reports a missing model before the file is read.
        try await runtime.prepare(options.whisperModel)

        return try await ChunkedTranscription.transcribeFile(at: url, speechDetector: speechDetector, progress: progress) { chunks in
            try await runtime.transcribe(chunks, options: options)
        }
    }

    /// Releases the loaded model, e.g. after it was deleted.
    package func unloadModel() async {
        await runtime.unload()
    }

    /// Whether a transcription is using the model right now; deleting it must wait.
    package var isInUse: Bool {
        get async { await runtime.isInUse }
    }
}

// MARK: - Runtime

/// Owns the WhisperKit pipeline. As an actor it serializes access to the (non-thread-safe)
/// pipeline: live and file transcription hand it chunks, never the pipeline itself.
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

    package init(modelStore: WhisperModelStore, idleDelay: Duration = WhisperRuntime.idleUnloadDelay) {
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

    /// Transcribes chunks of at most one Whisper window each; WhisperKit decodes them in
    /// parallel. The segments are on the recording timeline, in the order of the chunks.
    func transcribe(_ chunks: [NotifyAICore.AudioChunk], options: TranscriptionOptions) async throws -> [TranscriptSegment] {
        guard !chunks.isEmpty else { return [] }
        let duration = chunks.map(\.duration).reduce(0, +)
        let interval = Signposts.transcription.beginInterval("Whisper chunks", "\(chunks.count) chunks, \(duration, format: .fixed(precision: 1)) s")
        defer { Signposts.transcription.endInterval("Whisper chunks", interval) }
        let pipeline = try await pipeline(for: options.whisperModel)
        var decodeOptions = Self.decodingOptions(language: options.language)
        if let prompt = options.vocabulary.prompt, let tokenizer = pipeline.tokenizer {
            // The terms condition the decoder like text that came before; WhisperKit trims the
            // prompt to its maximum length and drops special tokens.
            decodeOptions.promptTokens = tokenizer.encode(text: prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        let results = await pipeline.transcribeWithResults(
            audioArrays: chunks.map(\.samples),
            decodeOptions: decodeOptions
        ) { _ in
            // Returning `false` stops decoding early.
            Task.isCancelled ? false : nil
        }
        try Task.checkCancellation()
        var segments: [TranscriptSegment] = []
        for (chunk, result) in zip(chunks, results) {
            segments += Self.segments(from: try result.get(), offset: chunk.startTime)
        }
        return segments
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
    /// prefill prompt and translates German speech. Special tokens are removed from the text,
    /// and a blank is never the first token of a text. Chunks are at most one window long,
    /// so WhisperKit does not chunk them again.
    static func decodingOptions(language: TranscriptionLanguage) -> DecodingOptions {
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
            suppressBlank: true,
            chunkingStrategy: ChunkingStrategy.none
        )
    }

    /// Above this compression ratio the text is a loop ("Danke. Danke. Danke."); Whisper's own
    /// threshold for a failed decoding.
    static let maximumCompressionRatio: Float = 2.4
    /// Below this average log probability Whisper considers a decoding failed.
    static let minimumAverageLogProbability: Float = -1
    /// Below this average the model itself does not believe the words it wrote.
    static let minimumMeanWordProbability: Float = 0.4

    /// Whether Whisper is confident enough in a segment to keep it.
    ///
    /// Whisper's no-speech probability cannot be used: WhisperKit (at the pinned revision)
    /// always reports 0. The values it does report decide instead. WhisperKit reports the
    /// compression ratio and the average log probability per decoded window, so they rate
    /// the whole chunk; the word probabilities rate the segment itself.
    static func isReliable(compressionRatio: Float, averageLogProbability: Float, wordProbabilities: [Float]) -> Bool {
        guard compressionRatio <= maximumCompressionRatio, averageLogProbability >= minimumAverageLogProbability else {
            return false
        }
        guard !wordProbabilities.isEmpty else { return true }
        let mean = wordProbabilities.reduce(0, +) / Float(wordProbabilities.count)
        return mean >= minimumMeanWordProbability
    }

    /// Converts WhisperKit results into segments on the recording timeline.
    static func segments(from results: [TranscriptionResult], offset: TimeInterval) -> [TranscriptSegment] {
        results.flatMap(\.segments).compactMap { segment in
            guard isReliable(
                compressionRatio: segment.compressionRatio,
                averageLogProbability: segment.avgLogprob,
                wordProbabilities: (segment.words ?? []).map(\.probability)
            ) else {
                Logger.transcription.info("Dropped an unreliable Whisper segment (\(segment.text.count, privacy: .public) characters)")
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
