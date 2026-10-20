//
//  ParakeetEngine.swift
//  NotifyAITranscription
//

import FluidAudio
import Foundation
import NotifyAICore
import NotifyAINeuralModels
import NotifyAISupport
import OSLog

/// Transcription with NVIDIA Parakeet TDT 0.6B on the Neural Engine (FluidAudio).
///
/// Parakeet transcribes 25 European languages, several times faster than Whisper and with
/// word timings from the decoder itself, which makes it well suited for live transcripts.
/// It takes the same path as Whisper (`ChunkedTranscription`): phrase-sized chunks with
/// speech only, each decoded from a fresh state. The language of the note is passed as a
/// hint, so the decoder prefers tokens of its script.
///
/// The model is loaded only from the downloaded folder (`AsrModels.loadLocal`), never fetched
/// implicitly, and released two minutes after the last use or on memory pressure.
package final class ParakeetEngine: TranscriptionEngine, NeuralModelUsage {
    package let kind = TranscriptionEngineKind.parakeet
    package let model = NeuralSpeechModel.parakeet
    private let store: NeuralModelStore
    private let speechDetector: SpeechDetector
    private let recognizer: LoadedModel<AsrManager>

    package init(store: NeuralModelStore, speechDetector: SpeechDetector = SpeechDetector()) {
        self.store = store
        self.speechDetector = speechDetector
        recognizer = LoadedModel(name: "Parakeet") {
            AsrManager(config: .default, models: try Self.loadModels(from: store))
        } release: { manager in
            await manager.cleanup()
        }
    }

    package var isInUse: Bool { get async { await recognizer.isInUse } }

    package func unloadModel() async {
        await recognizer.unload()
    }

    package func startLiveSession(options: TranscriptionOptions) async throws -> any LiveTranscriptionSession {
        // A missing model is reported before recording instead of silently producing no text.
        guard store.isInstalled(model) else { throw NeuralModelError.notInstalled(model) }
        _ = try await recognizer.use { _ in true }
        let recognizer = recognizer
        let language = Self.language(for: options.language)
        let vocabulary = options.vocabulary
        return ChunkedLiveSession(
            speechDetector: speechDetector,
            keepingModelLoaded: { work in try await recognizer.use { _ in try await work() } },
            transcribe: { chunks in vocabulary.corrected(try await Self.transcribe(chunks, with: recognizer, language: language)) }
        )
    }

    package func transcribeFile(
        at url: URL,
        options: TranscriptionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        guard store.isInstalled(model) else { throw NeuralModelError.notInstalled(model) }
        let recognizer = recognizer
        let speechDetector = speechDetector
        let language = Self.language(for: options.language)
        let vocabulary = options.vocabulary
        return try await recognizer.use { _ in
            try await ChunkedTranscription.transcribeFile(at: url, speechDetector: speechDetector, progress: progress) { chunks in
                // Parakeet takes no vocabulary; near-misses of the terms are corrected instead.
                vocabulary.corrected(try await Self.transcribe(chunks, with: recognizer, language: language))
            }
        }
    }

    // MARK: - Recognition

    private static func transcribe(_ chunks: [AudioChunk], with recognizer: LoadedModel<AsrManager>, language: Language?) async throws -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        for chunk in chunks {
            try Task.checkCancellation()
            let interval = Signposts.transcription.beginInterval("Parakeet chunk", "\(chunk.duration, format: .fixed(precision: 1)) s")
            let result = try await recognizer.use { manager in
                var state = TdtDecoderState.make()
                return try await manager.transcribe(chunk.samples, decoderState: &state, language: language)
            }
            Signposts.transcription.endInterval("Parakeet chunk", interval)
            let words = buildWordTimings(from: result.tokenTimings ?? []).map {
                TimedWord(text: $0.word, start: $0.startTime, end: $0.endTime)
            }
            segments += Self.segments(text: result.text, words: words, offset: chunk.startTime, duration: chunk.duration)
        }
        return segments
    }

    /// The language hint for the decoder; Parakeet supports all languages of the app.
    static func language(for language: TranscriptionLanguage) -> Language? {
        Language(rawValue: language.languageCode)
    }

    /// Longest segment: sentences are cut here even without punctuation.
    static let maximumSegmentDuration: TimeInterval = 20

    /// A word with its time in the chunk.
    struct TimedWord: Sendable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    /// Segments of one sentence each, with word timings on the recording timeline.
    ///
    /// The decoder returns the text of the whole chunk and a timing per sub-word token, which
    /// `buildWordTimings` groups into words (punctuation stays with its word). A sentence ends
    /// after a word with closing punctuation or at `maximumSegmentDuration`. Without timings
    /// the chunk becomes one segment.
    static func segments(text: String, words: [TimedWord], offset: TimeInterval, duration: TimeInterval) -> [TranscriptSegment] {
        let words = words.filter { !$0.text.isEmpty }
        guard !words.isEmpty else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [TranscriptSegment(start: offset, end: offset + duration, text: trimmed)]
        }
        var segments: [TranscriptSegment] = []
        var current: [TranscriptWord] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            segments.append(TranscriptSegment(start: first.start, end: last.end, text: text, words: current))
            current = []
        }
        for word in words {
            // As with Whisper, every word but the first of a segment starts with its space.
            let spelled = current.isEmpty ? word.text : " " + word.text
            current.append(TranscriptWord(text: spelled, start: offset + word.start, end: offset + max(word.end, word.start)))
            let sentenceEnds = word.text.last.map { ".?!…".contains($0) } ?? false
            if sentenceEnds || (current.last?.end ?? 0) - (current.first?.start ?? 0) >= maximumSegmentDuration {
                flush()
            }
        }
        flush()
        return segments
    }

    // MARK: - Models

    /// Loads the models from the downloaded folder only, compiled for this device.
    package func verifyDownload() throws {
        _ = try Self.loadModels(from: store)
    }

    static func loadModels(from store: NeuralModelStore) throws -> AsrModels {
        guard let folder = store.folder(for: .parakeet) else { throw NeuralModelError.notInstalled(.parakeet) }
        return try AsrModels.loadLocal(from: folder, version: NeuralSpeechModel.parakeetVersion)
    }
}
