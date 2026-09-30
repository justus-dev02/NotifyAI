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
}

/// Converts, mixes, writes and streams the recorded audio, away from the audio threads.
///
/// Two layers keep the real-time threads free of work that can block:
/// 1. The audio threads (`MicrophoneCaptureInput`, `AggregateCaptureInput`) only downmix
///    into lock-free ring buffers.
/// 2. A timer on a serial processing queue empties the rings every 100 ms: it converts each
///    source to 16 kHz mono, mixes them in blocks of `blockSize` samples, encodes and
///    writes the file, measures levels and streams the audio to live transcription.
///
/// A slow disk therefore delays only the processing queue; the rings absorb up to
/// `CaptureSource.bufferedSeconds` before audio is dropped (and logged).
///
/// All mutable state is protected by a mutex that the audio threads never take. Control
/// calls from the main actor (`setPaused`, `finish`, …) first process everything already
/// captured, so pausing and stopping happen exactly at the current position.
public final class AudioCaptureContext: Sendable {
    /// 100 ms: one level update, one source-activity bin and one transcription chunk per block.
    public static let blockSize = Int(AudioFormat.sampleRate * SourceActivity.binDuration)
    /// While no meter is visible, levels are published once per this many blocks (one second).
    public static let reducedLevelInterval = 10
    /// Below this much free space the recording stops before the disk runs full.
    public static let minimumFreeBytes: Int64 = 50 * 1_024 * 1_024
    private static let diskCheckInterval: Duration = .seconds(30)
    /// Largest block written at once (also the capacity of the reused write buffer).
    private static let writeCapacity = Int(AudioFormat.sampleRate)

    /// Converts one source from its native rate to 16 kHz mono with reused buffers.
    private struct SourceReader {
        let source: CaptureSource
        let converter: AVAudioConverter
        let inputBuffer: AVAudioPCMBuffer
        let outputBuffer: AVAudioPCMBuffer

        init(source: CaptureSource, outputFormat: AVAudioFormat) throws {
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
        func drain(into output: inout SampleFIFO) {
            guard let input = inputBuffer.floatChannelData?[0] else { return }
            while source.ring.availableToRead > 0 {
                let count = source.ring.read(into: input, maximumCount: Int(inputBuffer.frameCapacity))
                inputBuffer.frameLength = AVAudioFrameCount(count)
                convert(into: &output)
            }
        }

        private func convert(into output: inout SampleFIFO) {
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
            guard status != .error, outputBuffer.frameLength > 0, let samples = outputBuffer.floatChannelData?[0] else { return }
            output.append(UnsafeBufferPointer(start: samples, count: Int(outputBuffer.frameLength)))
        }
    }

    /// The number of written frames, readable without the lock.
    private final class FrameCounter: Sendable {
        let frames = Atomic<Int>(0)
    }

    private struct State {
        /// Shared with `recordedTime`; updated after every write.
        let counter: FrameCounter
        var sink: (any RecordingSink)?
        let outputFormat = AudioFormat.makeProcessingFormat()
        var writeBuffer: AVAudioPCMBuffer?
        var isPaused = false
        var isFinished = true
        var framesWritten: Int64 = 0
        var hasFailed = false
        var chunks: AsyncStream<AudioChunk>.Continuation?
        var levels: AsyncStream<AudioLevel>.Continuation?
        var events: AsyncStream<CaptureEvent>.Continuation?
        var storageDirectory: URL?
        var lastDiskCheck = ContinuousClock.now
        var hasReportedLowDiskSpace = false

        var microphone: SourceReader?
        var system: SourceReader?
        var pendingMicrophone = SampleFIFO()
        var pendingSystem = SampleFIFO()
        /// Samples discarded while paused, for keeping the meter moving at the block rate.
        var pausedSamples = 0
        var hasReceivedSystemAudio = false
        var activity: SourceActivityRecorder?

        var levelInterval = 1
        var blocksSinceLevelUpdate = 0

        var recordsMicrophone: Bool { microphone != nil }
        var recordsSystem: Bool { system != nil }
    }

    private let counter = FrameCounter()
    private let state: Mutex<State>
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

    /// Prepares a new recording.
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
        state.withLock { state in
            state = State(counter: counter)
            state.isFinished = false
            state.sink = sink
            state.writeBuffer = AVAudioPCMBuffer(pcmFormat: state.outputFormat, frameCapacity: AVAudioFrameCount(Self.writeCapacity))
            state.chunks = chunks
            state.levels = levels
            state.events = events
            state.storageDirectory = storageDirectory
            state.activity = recordsSourceActivity ? SourceActivityRecorder() : nil
        }
        counter.frames.store(0, ordering: .relaxed)
        startTimer()
    }

    /// Closes the file (which finalizes it) and finishes the streams.
    @discardableResult
    public func finish() -> RecordingResult {
        stopTimer()
        let result = state.withLock { state -> RecordingResult in
            guard !state.isFinished else {
                return RecordingResult(duration: Double(state.framesWritten) / AudioFormat.sampleRate, sourceActivity: nil)
            }
            Self.drain(&state)
            Self.flush(&state, force: true)
            let activity = state.activity.flatMap { $0.isEmpty ? nil : $0.makeActivity() }
            state.sink?.close()
            state.sink = nil
            state.microphone = nil
            state.system = nil
            state.pendingMicrophone.removeAll()
            state.pendingSystem.removeAll()
            state.chunks?.finish()
            state.levels?.finish()
            state.events?.finish()
            state.chunks = nil
            state.levels = nil
            state.events = nil
            state.isFinished = true
            return RecordingResult(duration: Double(state.framesWritten) / AudioFormat.sampleRate, sourceActivity: activity)
        }
        Self.logDroppedSamples(nil, nil, logger: logger)
        return result
    }

    // MARK: - Sources

    /// Prepares the microphone path (`AVAudioEngine`) for `format`. Audio of a previous
    /// format that is still buffered is processed first.
    public func configureMicrophone(format: AVAudioFormat) throws -> MicrophoneCaptureInput {
        let input = MicrophoneCaptureInput(format: format)
        try state.withLock { state in
            let reader = try SourceReader(source: input.source, outputFormat: state.outputFormat)
            Self.drain(&state)
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
            let system = try SourceReader(source: input.system, outputFormat: state.outputFormat)
            let microphone = try input.microphone.map { try SourceReader(source: $0, outputFormat: state.outputFormat) }
            Self.drain(&state)
            Self.alignPending(&state)
            state.system = system
            state.microphone = microphone
        }
        return input
    }

    // MARK: - Control

    public func setPaused(_ paused: Bool) {
        state.withLock { state in
            // Everything captured up to now belongs to the time before the change.
            Self.drain(&state)
            if paused, !state.isPaused {
                // Keep the audio that arrived right before the pause.
                Self.flush(&state, force: true)
            }
            state.isPaused = paused
            state.pausedSamples = 0
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
        state.withLock { state in
            state.chunks?.finish()
            state.chunks = nil
        }
    }

    /// Processes everything the audio threads have captured so far. Called by the timer;
    /// tests call it directly.
    public func processPendingAudio() {
        let signpost = CaptureSignposts.processing.beginInterval("Process captured audio")
        defer { CaptureSignposts.processing.endInterval("Process captured audio", signpost) }
        let dropped = state.withLock { state -> (microphone: Int, system: Int)? in
            guard !state.isFinished else { return nil }
            Self.drain(&state)
            Self.flush(&state, force: false)
            Self.checkDiskSpaceIfDue(&state)
            return (state.microphone?.source.ring.takeDroppedSamples() ?? 0, state.system?.source.ring.takeDroppedSamples() ?? 0)
        }
        if let dropped {
            Self.logDroppedSamples(dropped.microphone, dropped.system, logger: logger)
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

    // MARK: - Processing (inside the lock, on the processing queue or a control call)

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

    /// Writes complete blocks, or everything when `force` is set.
    private static func flush(_ state: inout State, force: Bool) {
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
            let mixed: ArraySlice<Float> = if let microphone, let system {
                mix(microphone, system)[...]
            } else {
                microphone ?? system ?? []
            }
            if let microphone, let system {
                state.activity?.append(microphone: microphone, system: system, startFrame: state.framesWritten)
            }
            write(mixed, to: &state)
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

    private static func write(_ samples: ArraySlice<Float>, to state: inout State) {
        guard !samples.isEmpty, !state.hasFailed, let buffer = state.writeBuffer, let channel = buffer.floatChannelData?[0] else { return }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: source.count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        do {
            try state.sink?.write(from: buffer)
        } catch {
            // The file is incomplete from here on; the timeline must not advance past it.
            state.hasFailed = true
            Logger.capture.error("Writing audio failed: \(error.localizedDescription, privacy: .public)")
            state.events?.yield(.writeFailed(error.localizedDescription))
            return
        }
        state.chunks?.yield(AudioChunk(samples: Array(samples), startFrame: state.framesWritten))
        state.framesWritten += Int64(samples.count)
        state.counter.frames.store(Int(state.framesWritten), ordering: .relaxed)
    }

    /// In the microphone + system mode the main meter shows the microphone and a second
    /// meter the system audio; with system audio only, the main meter shows the system audio.
    private static func yieldLevel(microphone: Float?, system: Float?, state: inout State) {
        state.blocksSinceLevelUpdate += 1
        guard state.blocksSinceLevelUpdate >= state.levelInterval else { return }
        state.blocksSinceLevelUpdate = 0
        let recordedTime = Double(state.framesWritten) / AudioFormat.sampleRate
        state.levels?.yield(AudioLevel(
            rms: microphone ?? system ?? 0,
            systemRMS: microphone == nil ? nil : system,
            recordedTime: recordedTime,
            hasReceivedSystemAudio: state.hasReceivedSystemAudio
        ))
    }

    private static func checkDiskSpaceIfDue(_ state: inout State) {
        guard !state.hasReportedLowDiskSpace, let directory = state.storageDirectory,
              ContinuousClock.now - state.lastDiskCheck >= diskCheckInterval
        else { return }
        state.lastDiskCheck = .now
        guard let available = DiskSpace.available(at: directory), available < minimumFreeBytes else { return }
        state.hasReportedLowDiskSpace = true
        Logger.capture.error("Only \(available, privacy: .public) bytes free, stopping the recording")
        state.events?.yield(.lowDiskSpace(availableBytes: available))
    }

    private static func rms(of samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return vDSP.rootMeanSquare(samples)
    }

    private static func logDroppedSamples(_ microphone: Int?, _ system: Int?, logger: Logger) {
        let microphone = microphone ?? 0
        let system = system ?? 0
        guard microphone > 0 || system > 0 else { return }
        logger.error("Capture processing fell behind; dropped \(microphone, privacy: .public) microphone and \(system, privacy: .public) system samples")
    }
}
