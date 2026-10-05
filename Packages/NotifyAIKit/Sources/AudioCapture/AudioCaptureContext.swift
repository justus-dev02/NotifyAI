//
//  AudioCaptureContext.swift
//  AudioCapture
//

import Accelerate
import AVFoundation
import OSLog
import NotifyAICore
import Synchronization

/// Converts, mixes, writes and streams the recorded audio, away from the audio threads.
///
/// Three layers keep blocking work away from the threads that must not block:
/// 1. The audio threads (`MicrophoneCaptureInput`, `AggregateCaptureInput`) only downmix
///    into lock-free ring buffers.
/// 2. Converting, mixing and metering happen under the `state` lock, in 100 ms blocks. The
///    finished blocks wait in `CaptureState.blocks`. This part is pure computation.
/// 3. Encoding and writing the file happen under the separate `writer` lock, on the
///    processing queue. Only this layer touches the disk.
///
/// Control calls from the main actor (`setPaused`, `configure…`, `setReducedLevelUpdates`)
/// take only the `state` lock, which is never held during file access: a stalled disk delays
/// the processing queue, never the main thread. Because these calls process everything
/// already captured, pausing happens exactly at the current position. `finish()` waits for
/// the remaining writes on the processing queue, asynchronously.
///
/// Lock order: `writer` before `state` and before `chunks`. `state` and `chunks` are only
/// held for short, non-blocking work.
public final class AudioCaptureContext: Sendable {
    /// 100 ms: one level update, one source-activity bin and one transcription chunk per block.
    public static let blockSize = Int(AudioFormat.sampleRate * SourceActivity.binDuration)
    /// While no meter is visible, levels are published once per this many blocks (one second).
    public static let reducedLevelInterval = 10
    /// Below this much free space the recording stops before the disk runs full.
    public static let minimumFreeBytes: Int64 = 50 * 1_024 * 1_024
    private static let diskCheckInterval: Duration = .seconds(30)
    /// Lost audio is logged at most this often (and when the capture is reconfigured or finished).
    static let lossReportInterval: Duration = .seconds(5)
    /// Largest block written at once (also the capacity of the reused write buffer).
    static let writeCapacity = Int(AudioFormat.sampleRate)

    /// The file side. Held while encoding and writing; the main thread never takes it.
    private struct Writer {
        var sink: (any RecordingSink)?
        var buffer: AVAudioPCMBuffer?
        var framesWritten: Int64 = 0
        var hasFailed = false
        var storageDirectory: URL?
        var lastDiskCheck = ContinuousClock.now
        var hasReportedLowDiskSpace = false
    }

    private let counter = FrameCounter()
    private let state: Mutex<CaptureState>
    private let writer = Mutex(Writer())
    /// Receives the written audio for live transcription.
    private let chunks = Mutex<AsyncStream<AudioChunk>.Continuation?>(nil)
    private let queue = DispatchQueue(label: "com.justus.NotifyAI.capture-processing", qos: .userInitiated)
    private let timer = Mutex<(any DispatchSourceTimer)?>(nil)
    private let tickInterval: DispatchTimeInterval
    private let logger = Logger.capture

    public init(tickInterval: DispatchTimeInterval = .milliseconds(100)) {
        self.tickInterval = tickInterval
        state = Mutex(CaptureState(counter: counter))
    }

    /// Recorded time so far, pauses excluded. Lock-free.
    public var recordedTime: TimeInterval {
        Double(counter.frames.load(ordering: .relaxed)) / AudioFormat.sampleRate
    }

    public var isPaused: Bool {
        state.withLock { $0.isPaused }
    }

    // MARK: - Lifecycle

    /// Prepares a new recording. Must not overlap with a running one: the previous
    /// recording's `finish()` has returned, so no processing runs and no lock is contended.
    /// - Parameters:
    ///   - chunks: Receives the recorded audio for live transcription; `nil` if nobody needs it.
    ///   - storageDirectory: Checked periodically for free space.
    public func begin(
        sink: any RecordingSink,
        chunks: AsyncStream<AudioChunk>.Continuation?,
        levels: AsyncStream<AudioLevel>.Continuation,
        events: AsyncStream<CaptureEvent>.Continuation? = nil,
        recordsSourceActivity: Bool,
        storageDirectory: URL? = nil
    ) {
        writer.withLock { writer in
            writer = Writer()
            writer.sink = sink
            writer.buffer = AVAudioPCMBuffer(pcmFormat: AudioFormat.makeProcessingFormat(), frameCapacity: AVAudioFrameCount(Self.writeCapacity))
            writer.storageDirectory = storageDirectory
        }
        self.chunks.withLock { $0 = chunks }
        state.withLock { state in
            state = CaptureState(counter: counter)
            state.isFinished = false
            state.levels = levels
            state.events = events
            state.activity = recordsSourceActivity ? SourceActivityRecorder() : nil
        }
        counter.frames.store(0, ordering: .relaxed)
        startTimer()
    }

    /// Writes what is left, closes the file (which finalizes it) and finishes the streams.
    ///
    /// Runs on the processing queue, after all writes that are still pending; the caller
    /// waits without blocking its thread.
    @discardableResult
    public func finish() async -> RecordingResult {
        stopTimer()
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.finishOnQueue())
            }
        }
    }

    private func finishOnQueue() -> RecordingResult {
        writer.withLock { writer in
            let taken = state.withLock { state -> (activity: SourceActivity?, wasFinished: Bool) in
                guard !state.isFinished else { return (nil, true) }
                state.drain()
                state.flush(force: true)
                state.reportLosses(force: true)
                let activity = state.activity.flatMap { $0.isEmpty ? nil : $0.makeActivity() }
                state.isFinished = true
                state.microphone = nil
                state.system = nil
                state.pendingMicrophone.removeAll()
                state.pendingSystem.removeAll()
                return (activity, false)
            }
            guard !taken.wasFinished else {
                return RecordingResult(duration: Double(writer.framesWritten) / AudioFormat.sampleRate, sourceActivity: nil)
            }
            writeBlocks(&writer)
            writer.sink?.close()
            writer.sink = nil
            chunks.withLock { continuation in
                continuation?.finish()
                continuation = nil
            }
            state.withLock { state in
                state.levels?.finish()
                state.events?.finish()
                state.levels = nil
                state.events = nil
            }
            return RecordingResult(duration: Double(writer.framesWritten) / AudioFormat.sampleRate, sourceActivity: taken.activity)
        }
    }

    // MARK: - Sources

    /// Prepares the microphone path (`AVAudioEngine`) for `format`. Audio of a previous
    /// format that is still buffered is processed first.
    public func configureMicrophone(format: AVAudioFormat) throws -> MicrophoneCaptureInput {
        let input = MicrophoneCaptureInput(format: format)
        try state.withLock { state in
            let reader = try SourceReader(source: input.source)
            state.drain()
            state.reportLosses(force: true)
            state.microphone = reader
            state.system = nil
        }
        return input
    }

    /// Prepares the aggregate path for a (new) aggregate device. Audio converted from the
    /// previous device is kept; the shorter source is padded so both stay aligned.
    public func configure(_ layout: AggregateInputLayout) throws -> AggregateCaptureInput {
        guard Self.isSupported(layout.system.streamFormat),
              layout.microphone.map({ Self.isSupported($0.streamFormat) }) ?? true
        else {
            throw CaptureError.unsupportedFormat
        }
        let input = AggregateCaptureInput(layout: layout)
        try state.withLock { state in
            let system = try SourceReader(source: input.system)
            let microphone = try input.microphone.map { try SourceReader(source: $0) }
            state.drain()
            state.reportLosses(force: true)
            state.alignPending()
            state.system = system
            state.microphone = microphone
        }
        return input
    }

    // MARK: - Control

    public func setPaused(_ paused: Bool) {
        let hasBlocks = state.withLock { state -> Bool in
            guard !state.isFinished else { return false }
            // Everything captured up to now belongs to the time before the change.
            state.drain()
            if paused, !state.isPaused {
                // Keep the audio that arrived right before the pause.
                state.flush(force: true)
            }
            state.isPaused = paused
            state.pausedSamples = 0
            return !state.blocks.isEmpty
        }
        if hasBlocks {
            // Written on the processing queue; this call never waits for the disk.
            queue.async { [weak self] in self?.writePendingBlocks() }
        }
    }

    /// Publishes levels ten times per second while a meter is visible, otherwise once per
    /// second (enough for the elapsed time), which saves main-thread wake-ups.
    public func setReducedLevelUpdates(_ reduced: Bool) {
        state.withLock { state in
            state.levelInterval = reduced ? Self.reducedLevelInterval : 1
        }
        rescheduleTimer(reduced: reduced)
    }

    /// Stops streaming audio to live transcription, e.g. when it fell too far behind.
    public func stopStreamingChunks() {
        chunks.withLock { continuation in
            continuation?.finish()
            continuation = nil
        }
    }

    /// Tells the recording controller that a device stopped delivering audio and could not
    /// be restarted. Called by the device layer (engine, aggregate device).
    public func reportInputFailure(_ message: String) {
        state.withLock { state in
            guard !state.isFinished else { return }
            state.events?.yield(.inputFailed(message))
        }
    }

    /// Processes everything the audio threads have captured so far and writes it. Called by
    /// the timer on the processing queue; tests call it directly. Safe from any thread, but
    /// it writes to the disk, so the app never calls it on the main thread.
    public func processPendingAudio() {
        let signpost = Signposts.capture.beginInterval("Process captured audio")
        defer { Signposts.capture.endInterval("Process captured audio", signpost) }
        let isRunning = state.withLock { state -> Bool in
            guard !state.isFinished else { return false }
            state.drain()
            state.flush(force: false)
            state.reportLosses(force: false)
            return true
        }
        guard isRunning else { return }
        writer.withLock { writer in
            writeBlocks(&writer)
            checkDiskSpaceIfDue(&writer)
        }
    }

    // MARK: - Timer

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            self?.processPendingAudio()
        }
        timer.schedule(deadline: .now() + tickInterval, repeating: tickInterval, leeway: .milliseconds(20))
        self.timer.withLock { current in
            current?.cancel()
            current = timer
        }
        timer.resume()
    }

    /// Wakes less often while nobody watches the meter; the rings hold far more than that.
    private func rescheduleTimer(reduced: Bool) {
        let interval: DispatchTimeInterval = reduced ? .milliseconds(500) : tickInterval
        timer.withLock { timer in
            timer?.schedule(deadline: .now() + interval, repeating: interval, leeway: reduced ? .milliseconds(100) : .milliseconds(20))
        }
    }

    private func stopTimer() {
        timer.withLock { timer in
            timer?.cancel()
            timer = nil
        }
    }

    // MARK: - Writing (under the writer lock)

    private func writePendingBlocks() {
        writer.withLock { writeBlocks(&$0) }
    }

    /// Writes every block produced so far, in timeline order, and streams it to live
    /// transcription afterwards, so the stream always matches the file.
    private func writeBlocks(_ writer: inout Writer) {
        let blocks = state.withLock { state -> [MixedBlock] in
            let blocks = state.blocks
            state.blocks.removeAll(keepingCapacity: true)
            return blocks
        }
        for block in blocks {
            guard !writer.hasFailed else { return }
            if let error = Self.write(block, to: &writer) {
                writer.hasFailed = true
                // The file ends here; the timeline must not go past it.
                counter.frames.store(Int(writer.framesWritten), ordering: .relaxed)
                logger.error("Writing audio failed: \(error, privacy: .public)")
                state.withLock { state in
                    state.hasFailed = true
                    state.blocks.removeAll()
                    state.events?.yield(.writeFailed(error))
                }
                return
            }
            chunks.withLock { continuation in
                _ = continuation?.yield(AudioChunk(samples: block.samples, startFrame: block.startFrame))
            }
        }
    }

    /// - Returns: The error description if writing failed.
    private static func write(_ block: MixedBlock, to writer: inout Writer) -> String? {
        guard !block.samples.isEmpty, let buffer = writer.buffer, let channel = buffer.floatChannelData?[0] else { return nil }
        block.samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: source.count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(block.samples.count)
        do {
            try writer.sink?.write(from: buffer)
        } catch {
            return error.localizedDescription
        }
        writer.framesWritten += Int64(block.samples.count)
        return nil
    }

    private func checkDiskSpaceIfDue(_ writer: inout Writer) {
        guard !writer.hasReportedLowDiskSpace, let directory = writer.storageDirectory,
              ContinuousClock.now - writer.lastDiskCheck >= Self.diskCheckInterval
        else { return }
        writer.lastDiskCheck = .now
        guard let available = DiskSpace.available(at: directory), available < Self.minimumFreeBytes else { return }
        writer.hasReportedLowDiskSpace = true
        logger.error("Only \(available, privacy: .public) bytes free, stopping the recording")
        state.withLock { state in
            _ = state.events?.yield(.lowDiskSpace(availableBytes: available))
        }
    }

    // MARK: - Processing (under the state lock, no file access)

    private static func isSupported(_ description: AudioStreamBasicDescription) -> Bool {
        description.mFormatID == kAudioFormatLinearPCM
            && description.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && description.mBitsPerChannel == 32
            && (description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 || description.mChannelsPerFrame == 1)
            && description.mSampleRate > 0
    }

    /// Sum of both sources, limited to the valid range. Speech rarely reaches full scale,
    /// so plain summing keeps both sides at their natural level.
    public static func mix(_ microphone: ArraySlice<Float>, _ system: ArraySlice<Float>) -> [Float] {
        let sum = vDSP.add(microphone, system)
        return vDSP.clip(sum, to: -1...1)
    }
}
