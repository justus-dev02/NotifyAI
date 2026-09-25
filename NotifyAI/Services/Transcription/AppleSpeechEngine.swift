//
//  AppleSpeechEngine.swift
//  NotifyAI
//

import AVFoundation
import CoreMedia
import OSLog
import Speech

/// Transcription with Apple's `SpeechAnalyzer` and `SpeechTranscriber`.
///
/// Unlike the older `SFSpeechRecognizer`, this API runs fully on device, handles
/// long-form audio and reports word-level timing through `audioTimeRange` attributes.
final class AppleSpeechEngine: TranscriptionEngine {
    let kind = TranscriptionEngineKind.appleSpeech

    func startLiveSession(options: TranscriptionOptions) async throws -> any LiveTranscriptionSession {
        let locale = try await Self.prepare(language: options.language)
        return try await AppleSpeechLiveSession.start(locale: locale)
    }

    func transcribeFile(
        at url: URL,
        options: TranscriptionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        let locale = try await Self.prepare(language: options.language)
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw TranscriptionError.unreadableAudio
        }
        let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate

        let results = transcriber.results
        let collector = Task {
            var segments: [TranscriptSegment] = []
            for try await result in results {
                guard let segment = Self.segment(from: result) else { continue }
                segments.append(segment)
                if duration > 0 {
                    progress(min(1, segment.end / duration))
                }
            }
            return segments
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            try await withTaskCancellationHandler {
                if let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) {
                    try await analyzer.finalizeAndFinish(through: lastSampleTime)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            collector.cancel()
            throw error
        }
        return Transcript.normalized(try await collector.value)
    }

    // MARK: - Shared helpers

    /// Resolves the locale and makes sure the on-device speech model is installed.
    static func prepare(language: TranscriptionLanguage) async throws -> Locale {
        // SpeechAnalyzer itself runs on device; asking once keeps behaviour identical on
        // systems that still gate it behind the speech-recognition permission.
        await SpeechRecognitionPermission.request()

        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale) else {
            throw TranscriptionError.languageNotSupported(language.displayName)
        }
        try await installAssetsIfNeeded(for: locale)
        return locale
    }

    static func assetStatus(for language: TranscriptionLanguage) async -> AssetInventory.Status {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale) else {
            return .unsupported
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        return await AssetInventory.status(forModules: [transcriber])
    }

    /// Downloads Apple's speech model for `locale` if it is missing. This is a one-time
    /// system download; audio is never sent anywhere.
    static func installAssetsIfNeeded(for locale: Locale) async throws {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return
        case .unsupported:
            throw TranscriptionError.speechAssetsUnavailable
        case .supported, .downloading:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                Logger.transcription.info("Installing speech assets for \(locale.identifier, privacy: .public)")
                try await request.downloadAndInstall()
            }
        @unknown default:
            return
        }
    }

    /// Converts a finalized recognizer result into a segment with word timing.
    static func segment(from result: SpeechTranscriber.Result) -> TranscriptSegment? {
        let text = String(result.text.characters)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        // Runs without a time range (spaces, punctuation) are attached to the neighbouring
        // word so that concatenating the words reproduces the text exactly.
        var words: [TranscriptWord] = []
        var pendingPrefix = ""
        for run in result.text.runs {
            let runText = String(result.text[run.range].characters)
            if let timeRange = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] {
                words.append(TranscriptWord(
                    text: pendingPrefix + runText,
                    start: timeRange.start.seconds,
                    end: timeRange.end.seconds
                ))
                pendingPrefix = ""
            } else if words.isEmpty {
                pendingPrefix += runText
            } else {
                words[words.count - 1].text += runText
            }
        }

        let start = result.range.start.seconds
        let end = result.range.end.seconds
        return TranscriptSegment(
            start: start.isFinite ? start : 0,
            end: end.isFinite ? end : start,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            words: words
        )
    }
}

// MARK: - Live session

/// Streams microphone audio into a `SpeechAnalyzer` and publishes volatile and final text.
private actor AppleSpeechLiveSession: LiveTranscriptionSession {
    nonisolated let events: AsyncStream<LiveTranscriptionEvent>

    private let eventContinuation: AsyncStream<LiveTranscriptionEvent>.Continuation
    private let inputStream: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let analyzer: SpeechAnalyzer
    private let converter: PCMConverter
    private let resultsTask: Task<[TranscriptSegment], any Error>
    private var isFinished = false

    static func start(locale: Locale) async throws -> AppleSpeechLiveSession {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            ?? AudioFormat.makeProcessingFormat()
        try await analyzer.prepareToAnalyze(in: analyzerFormat)

        let session = try AppleSpeechLiveSession(
            analyzer: analyzer,
            results: transcriber.results,
            analyzerFormat: analyzerFormat
        )
        try await session.startAnalyzing()
        return session
    }

    private init(
        analyzer: SpeechAnalyzer,
        results: some AsyncSequence<SpeechTranscriber.Result, any Error> & Sendable,
        analyzerFormat: AVAudioFormat
    ) throws {
        let (events, eventContinuation) = AsyncStream.makeStream(of: LiveTranscriptionEvent.self)
        let (inputStream, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.analyzer = analyzer
        self.converter = try PCMConverter(to: analyzerFormat)
        self.events = events
        self.eventContinuation = eventContinuation
        self.inputStream = inputStream
        self.inputContinuation = inputContinuation
        self.resultsTask = Task {
            var segments: [TranscriptSegment] = []
            for try await result in results {
                if result.isFinal {
                    if let segment = AppleSpeechEngine.segment(from: result) {
                        segments.append(segment)
                        eventContinuation.yield(.finalized([segment]))
                    }
                    eventContinuation.yield(.volatile(""))
                } else {
                    eventContinuation.yield(.volatile(String(result.text.characters)))
                }
            }
            return segments
        }
    }

    private func startAnalyzing() async throws {
        try await analyzer.start(inputSequence: inputStream)
    }

    func append(_ chunk: AudioChunk) {
        guard !isFinished else { return }
        do {
            let buffer = try converter.convert(chunk.samples)
            let startTime = CMTime(value: chunk.startFrame, timescale: CMTimeScale(AudioFormat.sampleRate))
            inputContinuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: startTime))
        } catch {
            Logger.transcription.error("Converting audio for Apple Speech failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func finish() async throws -> [TranscriptSegment] {
        guard !isFinished else { return try await resultsTask.value }
        isFinished = true
        inputContinuation.finish()
        defer { eventContinuation.finish() }
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return Transcript.normalized(try await resultsTask.value)
    }

    func cancel() async {
        guard !isFinished else { return }
        isFinished = true
        inputContinuation.finish()
        await analyzer.cancelAndFinishNow()
        resultsTask.cancel()
        eventContinuation.finish()
    }
}

// MARK: - Format conversion

/// Converts 16 kHz Float32 mono samples into the analyzer's preferred format.
private final class PCMConverter {
    private let inputFormat = AudioFormat.makeProcessingFormat()
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    init(to outputFormat: AVAudioFormat) throws {
        self.outputFormat = outputFormat
        if outputFormat == inputFormat {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw AudioRecorderError.converterUnavailable
            }
            self.converter = converter
        }
    }

    func convert(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        guard let input = AVAudioPCMBuffer.mono(samples, format: inputFormat) else {
            throw AudioRecorderError.converterUnavailable
        }
        guard let converter else { return input }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw AudioRecorderError.converterUnavailable
        }
        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if didProvideInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw conversionError ?? AudioRecorderError.converterUnavailable
        }
        return output
    }
}
