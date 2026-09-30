//
//  AudioCaptureContext.swift
//  AudioCapture
//

import Accelerate
import AVFoundation
import OSLog
import NotifyAICore
import Synchronization

/// Where the recorded audio is written. `AVAudioFile` in the app, a test double in tests.
public protocol RecordingSink: AnyObject, Sendable {
    func write(from buffer: AVAudioPCMBuffer) throws
    func close()
}

extension AVAudioFile: RecordingSink {}

/// Something the running capture reports to the recording controller.
public enum CaptureEvent: Sendable, Equatable {
    /// Writing the audio file failed (e.g. the disk is full). No more audio is recorded.
    case writeFailed(String)
    /// The volume holding the recording is almost full; the recording should stop.
    case lowDiskSpace(availableBytes: Int64)
    /// An audio device stopped delivering and could not be restarted (e.g. the microphone
    /// was disconnected and no other one is available). Nothing is recorded until the
    /// recording is resumed successfully.
    case inputFailed(String)
}

/// Converts, mixes, writes and streams the recorded audio, away from the audio threads.
///
/// Three layers keep blocking work away from the threads that must not block:
/// 1. The audio threads (`MicrophoneCaptureInput`, `AggregateCaptureInput`) only downmix
///    into lock-free ring buffers.
/// 2. Converting, mixing and metering happen under the `state` lock, in 100 ms blocks. The
///    finished blocks wait in `State.blocks`. This part is pure computation.
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
    private static let lossReportInterval: Duration = .seconds(5)
    /// Largest block written at once (also the capacity of the reused write buffer).
    private static let writeCapacity = Int(AudioFormat.sampleRate)

    /// Audio a source lost before it reached the file.
    private struct SampleLosses {
        /// Dropped by the audio thread because the ring was full.
        var dropped = 0
        /// Lost because converting to 16 kHz failed.
        var failedConversion = 0
        /// The latest conversion error.
        var conversionError: String?

        var isEmpty: Bool { dropped == 0 && failedConversion == 0 }

        mutating func add(_ other: SampleLosses) {
            dropped += other.dropped
            failedConversion += other.failedConversion
            conversionError = other.conversionError ?? conversionError
        }
    }

    /// Converts one source from its native rate to 16 kHz mono with reused buffers.
    private struct SourceReader {
        let source: CaptureSource
        let converter: AVAudioConverter
        let inputBuffer: AVAudioPCMBuffer
        let outputBuffer: AVAudioPCMBuffer
        /// Samples lost to conversion errors since the last `takeLosses()`.
        private var failedConversion = 0
        private var conversionError: String?

        init(source: CaptureSource) throws {
            let outputFormat = AudioFormat.makeProcessingFormat()
            // The rings hold downmixed mono at the source's rate.
            guard let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: source.sampleRate,
                channels: 1,
                interleaved: false
            ),
                let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            else {
                throw CaptureError.unsupportedFormat
            }
            // A tenth of a second per conversion, matching the processing interval.
            let inputCapacity = AVAudioFrameCount(max(1_024, (source.sampleRate / 10).rounded(.up)))
            let outputCapacity = AVAudioFrameCount((Double(inputCapacity) * outputFormat.sampleRate / source.sampleRate).rounded(.up)) + 64
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputCapacity),
                  let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity)
            else {
                throw CaptureError.unsupportedFormat
            }
            self.source = source
            self.converter = converter
            self.inputBuffer = inputBuffer
            self.outputBuffer = outputBuffer
        }

        /// Converts everything in the ring and appends it to `output`.
        mutating func drain(into output: inout SampleFIFO) {
            guard let input = inputBuffer.floatChannelData?[0] else { return }
            while source.ring.availableToRead > 0 {
                let count = source.ring.read(into: input, maximumCount: Int(inputBuffer.frameCapacity))
                inputBuffer.frameLength = AVAudioFrameCount(count)
                if let error = convert(into: &output) {
                    failedConversion += count
                    conversionError = error
                }
            }
        }

        /// Losses since the last call: samples the audio thread dropped and samples that
        /// could not be converted.
        mutating func takeLosses() -> SampleLosses {
            let losses = SampleLosses(dropped: source.ring.takeDroppedSamples(), failedConversion: failedConversion, conversionError: conversionError)
            failedConversion = 0
            conversionError = nil
            return losses
        }

        /// - Returns: The error description if the conversion failed; the input is then lost.
        private func convert(into output: inout SampleFIFO) -> String? {
            outputBuffer.frameLength = 0
            var didProvideInput = false
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                if didProvideInput {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                didProvideInput = true
                inputStatus.pointee = .haveData
                return inputBuffer
            }
            if status == .error {
                return conversionError?.localizedDescription ?? "AVAudioConverter status error"
            }
            guard outputBuffer.frameLength > 0, let samples = outputBuffer.floatChannelData?[0] else { return nil }
            output.append(UnsafeBufferPointer(start: samples, count: Int(outputBuffer.frameLength)))
            return nil
        }
    }

    /// The number of frames on the recording timeline, readable without a lock.
    private final class FrameCounter: Sendable {
        let frames = Atomic<Int>(0)
    }

    /// A mixed block of 16 kHz mono samples, waiting to be written.
    private struct MixedBlock: Sendable {
        let samples: [Float]
        let startFrame: Int64
    }

    /// Conversion, mixing and metering. Never held while touching the disk.
    private struct State {
        /// Shared with `recordedTime`; updated whenever a block is added to the timeline.
        let counter: FrameCounter
        var isPaused = false
        var isFinished = true
        /// Frames on the recording timeline: every block handed to the writer.
        var framesProduced: Int64 = 0
        /// Set by the writer after a write error; nothing is produced afterwards.
        var hasFailed = false
        var levels: AsyncStream<AudioLevel>.Continuation?
        var events: AsyncStream<CaptureEvent>.Continuation?

        var microphone: SourceReader?
        var system: SourceReader?
        var pendingMicrophone = SampleFIFO()
        var pendingSystem = SampleFIFO()
        /// Blocks in timeline order that the writer has not taken yet.
        var blocks: [MixedBlock] = []
        /// Samples discarded while paused, for keeping the meter moving at the block rate.
        var pausedSamples = 0
        var hasReceivedSystemAudio = false
        var activity: SourceActivityRecorder?

        var levelInterval = 1
        var blocksSinceLevelUpdate = 0

        /// Losses collected but not logged yet (see `lossReportInterval`).
        var unreportedMicrophoneLosses = SampleLosses()
        var unreportedSystemLosses = SampleLosses()
        var lastLossReport = ContinuousClock.now

        var recordsMicrophone: Bool { microphone != nil }
        var recordsSystem: Bool { system != nil }
    }

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
    private let state: Mutex<State>
    private let writer = Mutex(Writer())
    /// Receives the written audio for live transcription.
    private let chunks = Mutex<AsyncStream<AudioChunk>.Continuation?>(nil)
    private let queue = DispatchQueue(label: "com.justus.NotifyAI.capture-processing", qos: .userInitiated)
    private let timer = Mutex<(any DispatchSourceTimer)?>(nil)
    private let tickInterval: DispatchTimeInterval
    private let logger = Logger.capture

    public init(tickInterval: DispatchTimeInterval = .milliseconds(100)) {
        self.tickInterval = tickInterval
        state = Mutex(State(counter: counter))
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
            state = State(counter: counter)
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
                Self.drain(&state)
                Self.flush(&state, force: true)
                Self.reportLosses(&state, force: true)
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
            Self.drain(&state)
            Self.reportLosses(&state, force: true)
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
            Self.drain(&state)
            Self.reportLosses(&state, force: true)
            Self.alignPending(&state)
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
            Self.drain(&state)
            if paused, !state.isPaused {
                // Keep the audio that arrived right before the pause.
                Self.flush(&state, force: true)
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
        let signpost = CaptureSignposts.processing.beginInterval("Process captured audio")
        defer { CaptureSignposts.processing.endInterval("Process captured audio", signpost) }
        let isRunning = state.withLock { state -> Bool in
            guard !state.isFinished else { return false }
            Self.drain(&state)
            Self.flush(&state, force: false)
            Self.reportLosses(&state, force: false)
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

    /// Converts everything the rings hold. While paused the audio is converted anyway (the
    /// resamplers keep their state, so resuming does not click) and then discarded.
    private static func drain(_ state: inout State) {
        state.microphone?.drain(into: &state.pendingMicrophone)
        state.system?.drain(into: &state.pendingSystem)

        guard state.isPaused || state.hasFailed else { return }
        let discarded = state.recordsMicrophone ? state.pendingMicrophone.count : state.pendingSystem.count
        state.pendingMicrophone.removeAll()
        state.pendingSystem.removeAll()
        state.pausedSamples += discarded
        while state.pausedSamples >= blockSize {
            state.pausedSamples -= blockSize
            yieldLevel(microphone: state.recordsMicrophone ? 0 : nil, system: state.recordsSystem ? 0 : nil, state: &state)
        }
    }

    /// Mixes complete blocks, or everything when `force` is set, and hands them to the writer.
    private static func flush(_ state: inout State, force: Bool) {
        guard !state.hasFailed else { return }
        if force {
            alignPending(&state)
        }
        while true {
            let available: Int = switch (state.recordsMicrophone, state.recordsSystem) {
            case (true, true): min(state.pendingMicrophone.count, state.pendingSystem.count)
            case (true, false): state.pendingMicrophone.count
            case (false, true): state.pendingSystem.count
            case (false, false): 0
            }
            guard available > 0, force || available >= blockSize else { return }
            let count = min(available, force ? writeCapacity : blockSize)
            let microphone = state.recordsMicrophone ? state.pendingMicrophone.prefix(count) : nil
            let system = state.recordsSystem ? state.pendingSystem.prefix(count) : nil

            if let system, !state.hasReceivedSystemAudio, vDSP.maximumMagnitude(system) > 0 {
                // A denied permission delivers digital silence, so this is the only sign of success.
                state.hasReceivedSystemAudio = true
            }
            let mixed: [Float] = if let microphone, let system {
                mix(microphone, system)
            } else {
                Array(microphone ?? system ?? [])
            }
            if let microphone, let system {
                state.activity?.append(microphone: microphone, system: system, startFrame: state.framesProduced)
            }
            state.blocks.append(MixedBlock(samples: mixed, startFrame: state.framesProduced))
            state.framesProduced += Int64(mixed.count)
            state.counter.frames.store(Int(state.framesProduced), ordering: .relaxed)
            yieldLevel(
                microphone: microphone.map { rms(of: $0) },
                system: system.map { rms(of: $0) },
                state: &state
            )

            if state.recordsMicrophone { state.pendingMicrophone.removeFirst(count) }
            if state.recordsSystem { state.pendingSystem.removeFirst(count) }
        }
    }

    /// Pads the shorter pending source with silence so both have the same length.
    private static func alignPending(_ state: inout State) {
        guard state.recordsMicrophone, state.recordsSystem else { return }
        let difference = state.pendingSystem.count - state.pendingMicrophone.count
        if difference > 0 {
            state.pendingMicrophone.appendSilence(difference)
        } else {
            state.pendingSystem.appendSilence(-difference)
        }
    }

    /// Sum of both sources, limited to the valid range. Speech rarely reaches full scale,
    /// so plain summing keeps both sides at their natural level.
    public static func mix(_ microphone: ArraySlice<Float>, _ system: ArraySlice<Float>) -> [Float] {
        let sum = vDSP.add(microphone, system)
        return vDSP.clip(sum, to: -1...1)
    }

    /// In the microphone + system mode the main meter shows the microphone and a second
    /// meter the system audio; with system audio only, the main meter shows the system audio.
    private static func yieldLevel(microphone: Float?, system: Float?, state: inout State) {
        state.blocksSinceLevelUpdate += 1
        guard state.blocksSinceLevelUpdate >= state.levelInterval else { return }
        state.blocksSinceLevelUpdate = 0
        let recordedTime = Double(state.framesProduced) / AudioFormat.sampleRate
        state.levels?.yield(AudioLevel(
            rms: microphone ?? system ?? 0,
            systemRMS: microphone == nil ? nil : system,
            recordedTime: recordedTime,
            hasReceivedSystemAudio: state.hasReceivedSystemAudio
        ))
    }

    private static func rms(of samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return vDSP.rootMeanSquare(samples)
    }

    /// Collects the audio the sources lost (full rings, failed conversions) and logs it,
    /// at most every `lossReportInterval` unless `force` is set. Nothing is lost silently,
    /// and a persistent problem does not flood the log.
    private static func reportLosses(_ state: inout State, force: Bool) {
        if let losses = state.microphone?.takeLosses() {
            state.unreportedMicrophoneLosses.add(losses)
        }
        if let losses = state.system?.takeLosses() {
            state.unreportedSystemLosses.add(losses)
        }
        let microphone = state.unreportedMicrophoneLosses
        let system = state.unreportedSystemLosses
        guard !microphone.isEmpty || !system.isEmpty,
              force || ContinuousClock.now - state.lastLossReport >= lossReportInterval
        else { return }
        state.lastLossReport = .now
        state.unreportedMicrophoneLosses = SampleLosses()
        state.unreportedSystemLosses = SampleLosses()

        if microphone.dropped > 0 || system.dropped > 0 {
            Logger.capture.error("Capture processing fell behind; dropped \(microphone.dropped, privacy: .public) microphone and \(system.dropped, privacy: .public) system samples")
        }
        if microphone.failedConversion > 0 || system.failedConversion > 0 {
            let reason = microphone.conversionError ?? system.conversionError ?? "unknown"
            Logger.capture.error("Converting captured audio failed (\(reason, privacy: .public)); lost \(microphone.failedConversion, privacy: .public) microphone and \(system.failedConversion, privacy: .public) system samples")
        }
    }
}
