//
//  ChunkedTranscription.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore
import Synchronization

/// The path Whisper and Parakeet share, for live audio and files: `SpeechChunker` cuts
/// phrase-sized chunks, `SpeechDetector` lets only chunks with speech through, and the engine
/// transcribes them. Recognizers invent text for silence and noise, so audio without speech
/// never reaches them.
enum ChunkedTranscription {
    /// Transcribes `[AudioChunk]` into segments on the recording timeline.
    typealias Transcribe = @Sendable ([AudioChunk]) async throws -> [TranscriptSegment]

    /// Reads the file block by block and transcribes it like a live recording.
    static func transcribeFile(
        at url: URL,
        speechDetector: SpeechDetector,
        progress: @escaping @Sendable (Double) -> Void,
        transcribe: Transcribe
    ) async throws -> [TranscriptSegment] {
        var chunker = SpeechChunker()
        var position: Int64 = 0
        var segments: [TranscriptSegment] = []
        try await SpeakerDiarizer.forEachMonoBlock(in: url) { block, fraction in
            let chunks = chunker.append(AudioChunk(samples: block, startFrame: position))
            position += Int64(block.count)
            segments += try await transcribe(chunks.filter { speechDetector.containsSpeech($0.samples) })
            progress(fraction)
        }
        if let tail = chunker.flush(), speechDetector.containsSpeech(tail.samples) {
            segments += try await transcribe([tail])
        }
        progress(1)
        return Transcript.normalized(segments)
    }
}

/// Cuts the live audio into phrase-sized chunks and transcribes them one after another;
/// chunks without speech are skipped.
///
/// Each chunk is transcribed exactly once, so the work grows linearly with the recording.
/// If transcription falls behind, chunks queue up; the session reports how much audio is
/// waiting (`.backlog`), so the feed can give up on live transcription before the queue
/// grows without bound. Whatever is queued is completed in `finish()`.
actor ChunkedLiveSession: LiveTranscriptionSession {
    /// Runs the session's whole work while the engine keeps its model loaded.
    typealias KeepModelLoaded = @Sendable (_ work: @Sendable () async throws -> [TranscriptSegment]) async throws -> [TranscriptSegment]

    nonisolated let events: AsyncStream<LiveTranscriptionEvent>

    private let eventContinuation: AsyncStream<LiveTranscriptionEvent>.Continuation
    private let chunkContinuation: AsyncStream<AudioChunk>.Continuation
    private let worker: Task<[TranscriptSegment], any Error>
    /// Seconds of audio handed to the worker and not transcribed yet.
    private let queue: QueuedAudio
    private var chunker = SpeechChunker()
    private var isFinished = false

    init(
        speechDetector: SpeechDetector,
        keepingModelLoaded keepLoaded: @escaping KeepModelLoaded,
        transcribe: @escaping ChunkedTranscription.Transcribe
    ) {
        let (events, eventContinuation) = AsyncStream.makeStream(of: LiveTranscriptionEvent.self)
        let (chunks, chunkContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let queue = QueuedAudio()
        self.events = events
        self.eventContinuation = eventContinuation
        self.chunkContinuation = chunkContinuation
        self.queue = queue
        self.worker = Task {
            try await keepLoaded {
                var transcript: [TranscriptSegment] = []
                for await chunk in chunks {
                    try Task.checkCancellation()
                    let segments = speechDetector.containsSpeech(chunk.samples) ? try await transcribe([chunk]) : []
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
    }

    func append(_ chunk: AudioChunk) {
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

/// Seconds of audio waiting for the worker; shared by the session and its worker.
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
