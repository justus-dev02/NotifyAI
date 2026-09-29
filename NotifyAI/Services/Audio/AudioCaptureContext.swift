//
//  AudioCaptureContext.swift
//  NotifyAI
//

import Accelerate
import AVFoundation
import OSLog
import Synchronization

/// Where microphone and system audio sit in the input of a Core Audio aggregate device.
///
/// The aggregate delivers one buffer per input stream: first the streams of its clock
/// device (the microphone, or the output device when only system audio is recorded),
/// then the stream of the process tap.
struct AggregateInputLayout: Sendable {
    struct Source: Sendable {
        let bufferIndex: Int
        /// Linear PCM Float32, interleaved (the virtual format of the aggregate's stream).
        let streamFormat: AudioStreamBasicDescription
    }

    /// `nil` when only system audio is recorded.
    let microphone: Source?
    let system: Source
}

/// State shared between the main actor and the audio threads while recording.
///
/// Every source is converted to 16 kHz mono. The microphone-only path (AVAudioEngine)
/// writes each converted buffer directly. The aggregate path (microphone and/or system
/// audio on the Mac) collects both converted streams, mixes them in blocks of
/// `blockSize` samples and records the level of each source for speaker attribution.
///
/// All state is protected by a mutex; the audio threads never touch the main actor.
final class AudioCaptureContext: Sendable {
    /// 100 ms: one level update and one transcription chunk per block, as with the microphone path.
    static let blockSize = Int(AudioFormat.sampleRate * SourceActivity.binDuration)

    private struct SourceConverter {
        let inputFormat: AVAudioFormat
        let converter: AVAudioConverter
        /// Reused for every callback; grown when a larger buffer arrives.
        var inputBuffer: AVAudioPCMBuffer
    }

    private struct State {
        var file: AVAudioFile?
        var outputFormat = AudioFormat.makeProcessingFormat()
        var isPaused = false
        var framesWritten: Int64 = 0
        var hasLoggedWriteError = false
        var chunks: AsyncStream<AudioChunk>.Continuation?
        var levels: AsyncStream<AudioLevel>.Continuation?

        /// Microphone path (AVAudioEngine).
        var engineConverter: AVAudioConverter?

        /// Aggregate path.
        var aggregateLayout: AggregateInputLayout?
        var microphoneSource: SourceConverter?
        var systemSource: SourceConverter?
        var recordsMicrophone = false
        var pendingMicrophone: [Float] = []
        var pendingSystem: [Float] = []
        var samplesSinceLevelUpdate = 0
        var hasReceivedSystemAudio = false
        var activity: SourceActivityRecorder?
    }

    private let state = Mutex(State())

    var recordedTime: TimeInterval {
        state.withLock { Double($0.framesWritten) / AudioFormat.sampleRate }
    }

    var isPaused: Bool {
        state.withLock { $0.isPaused }
    }

    func begin(
        file: AVAudioFile,
        chunks: AsyncStream<AudioChunk>.Continuation,
        levels: AsyncStream<AudioLevel>.Continuation,
        recordsSourceActivity: Bool
    ) {
        state.withLock { state in
            state = State()
            state.file = file
            state.chunks = chunks
            state.levels = levels
            state.activity = recordsSourceActivity ? SourceActivityRecorder() : nil
        }
    }

    func setEngineConverter(_ converter: AVAudioConverter) {
        state.withLock { $0.engineConverter = converter }
    }

    /// Prepares converters for a (new) aggregate device. Samples converted from the previous
    /// device are kept; the shorter source is padded so both stay aligned.
    func configure(_ layout: AggregateInputLayout) throws {
        try state.withLock { state in
            // Created inside the lock: converters are not `Sendable` and must stay in the state's region.
            let system = try Self.makeSourceConverter(for: layout.system.streamFormat)
            let microphone = try layout.microphone.map { try Self.makeSourceConverter(for: $0.streamFormat) }
            Self.alignPending(&state)
            state.systemSource = system
            state.microphoneSource = microphone
            state.recordsMicrophone = microphone != nil
            state.aggregateLayout = layout
        }
    }

    func setPaused(_ paused: Bool) {
        state.withLock { state in
            if paused, !state.isPaused {
                // Keep the audio that arrived right before the pause.
                Self.flush(&state, force: true)
            }
            state.isPaused = paused
        }
    }

    /// Closes the file (which finalizes it) and finishes the streams.
    @discardableResult
    func finish() -> RecordingResult {
        state.withLock { state in
            Self.flush(&state, force: true)
            let activity = state.activity.flatMap { $0.isEmpty ? nil : $0.makeActivity() }
            state.file = nil
            state.engineConverter = nil
            state.aggregateLayout = nil
            state.microphoneSource = nil
            state.systemSource = nil
            state.chunks?.finish()
            state.levels?.finish()
            state.chunks = nil
            state.levels = nil
            return RecordingResult(
                duration: Double(state.framesWritten) / AudioFormat.sampleRate,
                sourceActivity: activity
            )
        }
    }

    // MARK: - Microphone path

    /// Called on the AVAudioEngine tap thread for every microphone buffer.
    func process(_ input: AVAudioPCMBuffer) {
        state.withLock { state in
            guard let converter = state.engineConverter else { return }
            // The converter keeps its resampling state between calls, so it must see every
            // buffer (also while paused) to avoid clicks when writing resumes.
            let samples = Self.convert(input, with: converter, to: state.outputFormat)
            guard !samples.isEmpty else { return }
            let rms = Self.rms(of: samples[...])

            if !state.isPaused {
                Self.write(samples[...], to: &state)
            }
            let recordedTime = Double(state.framesWritten) / AudioFormat.sampleRate
            state.levels?.yield(AudioLevel(rms: state.isPaused ? 0 : rms, systemRMS: nil, recordedTime: recordedTime, hasReceivedSystemAudio: false))
        }
    }

    // MARK: - Aggregate path

    /// Called on the aggregate device's I/O queue with the input of all streams.
    func process(aggregateInput input: UnsafePointer<AudioBufferList>) {
        // Copy the interleaved samples out of Core Audio's buffers first; they are only valid
        // during this call and must not end up in the mutex-protected state.
        guard let layout = state.withLock({ $0.aggregateLayout }) else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard layout.system.bufferIndex < buffers.count else { return }
        let systemInput = Self.samples(of: buffers[layout.system.bufferIndex])
        let microphoneInput = layout.microphone.flatMap { source in
            source.bufferIndex < buffers.count ? Self.samples(of: buffers[source.bufferIndex]) : nil
        }

        state.withLock { state in
            guard var system = state.systemSource else { return }
            let systemSamples = Self.convert(interleaved: systemInput, using: &system, to: state.outputFormat)
            state.systemSource = system
            if !state.hasReceivedSystemAudio, !systemSamples.isEmpty, vDSP.maximumMagnitude(systemSamples) > 0 {
                // A denied permission delivers digital silence, so this is the only sign of success.
                state.hasReceivedSystemAudio = true
            }

            var microphoneSamples: [Float] = []
            if let microphoneInput, var microphone = state.microphoneSource {
                microphoneSamples = Self.convert(interleaved: microphoneInput, using: &microphone, to: state.outputFormat)
                state.microphoneSource = microphone
            }

            if state.isPaused {
                // Converted anyway to keep the resampler state continuous; the audio is dropped.
                state.samplesSinceLevelUpdate += systemSamples.count
                if state.samplesSinceLevelUpdate >= Self.blockSize {
                    state.samplesSinceLevelUpdate = 0
                    Self.yieldLevel(microphone: state.recordsMicrophone ? 0 : nil, system: 0, state: &state)
                }
                return
            }

            state.pendingSystem.append(contentsOf: systemSamples)
            if state.recordsMicrophone {
                state.pendingMicrophone.append(contentsOf: microphoneSamples)
            }
            Self.flush(&state, force: false)
        }
    }

    // MARK: - Private

    private static func makeSourceConverter(for description: AudioStreamBasicDescription) throws -> SourceConverter {
        var description = description
        guard description.mFormatID == kAudioFormatLinearPCM,
              description.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              description.mBitsPerChannel == 32,
              description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 || description.mChannelsPerFrame == 1,
              let format = AVAudioFormat(streamDescription: &description),
              let converter = AVAudioConverter(from: format, to: AudioFormat.makeProcessingFormat()),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192)
        else {
            throw AudioRecorderError.converterUnavailable
        }
        // Mix all channels (the tap is stereo, some microphones have several channels).
        converter.downmix = true
        return SourceConverter(inputFormat: format, converter: converter, inputBuffer: buffer)
    }

    /// The Float32 samples of one aggregate stream buffer (interleaved).
    private static func samples(of buffer: AudioBuffer) -> [Float] {
        guard let data = buffer.mData else { return [] }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
    }

    /// Copies interleaved samples into the reusable input buffer and converts them.
    private static func convert(interleaved samples: [Float], using source: inout SourceConverter, to outputFormat: AVAudioFormat) -> [Float] {
        let channels = Int(source.inputFormat.channelCount)
        let frames = channels > 0 ? samples.count / channels : 0
        guard frames > 0 else { return [] }

        if Int(source.inputBuffer.frameCapacity) < frames {
            guard let larger = AVAudioPCMBuffer(pcmFormat: source.inputFormat, frameCapacity: AVAudioFrameCount(frames)) else { return [] }
            source.inputBuffer = larger
        }
        let target = UnsafeMutableAudioBufferListPointer(source.inputBuffer.mutableAudioBufferList)
        guard let destination = target[0].mData else { return [] }
        let byteCount = frames * channels * MemoryLayout<Float>.size
        samples.withUnsafeBytes { destination.copyMemory(from: $0.baseAddress!, byteCount: byteCount) }
        target[0].mDataByteSize = UInt32(byteCount)
        source.inputBuffer.frameLength = AVAudioFrameCount(frames)
        return convert(source.inputBuffer, with: source.converter, to: outputFormat)
    }

    private static func convert(_ input: AVAudioPCMBuffer, with converter: AVAudioConverter, to outputFormat: AVAudioFormat) -> [Float] {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }

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
        guard status != .error, output.frameLength > 0 else { return [] }
        return output.monoSamples
    }

    /// Writes complete blocks (or everything, when `force` is set) of the aggregate path.
    private static func flush(_ state: inout State, force: Bool) {
        while true {
            if force {
                alignPending(&state)
                guard !state.pendingSystem.isEmpty else { return }
            } else {
                let available = state.recordsMicrophone
                    ? min(state.pendingMicrophone.count, state.pendingSystem.count)
                    : state.pendingSystem.count
                guard available >= blockSize else { return }
            }
            let count = force ? state.pendingSystem.count : blockSize
            let system = state.pendingSystem[..<count]
            let microphone = state.recordsMicrophone ? state.pendingMicrophone[..<count] : nil

            let mixed: ArraySlice<Float> = if let microphone { mix(microphone, system)[...] } else { system }
            let startFrame = state.framesWritten
            state.activity?.append(microphone: microphone ?? ArraySlice(repeating: 0, count: count), system: system, startFrame: startFrame)
            write(mixed, to: &state)
            yieldLevel(microphone: microphone.map { rms(of: $0) }, system: rms(of: system), state: &state)

            state.pendingSystem.removeFirst(count)
            if state.recordsMicrophone {
                state.pendingMicrophone.removeFirst(count)
            }
            if force { return }
        }
    }

    /// Pads the shorter pending source with silence so both have the same length.
    private static func alignPending(_ state: inout State) {
        guard state.recordsMicrophone else { return }
        let difference = state.pendingSystem.count - state.pendingMicrophone.count
        if difference > 0 {
            state.pendingMicrophone.append(contentsOf: repeatElement(0, count: difference))
        } else if difference < 0 {
            state.pendingSystem.append(contentsOf: repeatElement(0, count: -difference))
        }
    }

    /// Sum of both sources, limited to the valid range. Speech rarely reaches full scale,
    /// so plain summing keeps both sides at their natural level.
    static func mix(_ microphone: ArraySlice<Float>, _ system: ArraySlice<Float>) -> [Float] {
        let sum = vDSP.add(microphone, system)
        return vDSP.clip(sum, to: -1...1)
    }

    private static func write(_ samples: ArraySlice<Float>, to state: inout State) {
        guard !samples.isEmpty else { return }
        if let buffer = AVAudioPCMBuffer.mono(Array(samples), format: state.outputFormat) {
            do {
                try state.file?.write(from: buffer)
            } catch {
                // Log once; a full disk would otherwise flood the log ten times per second.
                if !state.hasLoggedWriteError {
                    state.hasLoggedWriteError = true
                    Logger.audio.error("Writing audio failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        state.chunks?.yield(AudioChunk(samples: Array(samples), startFrame: state.framesWritten))
        state.framesWritten += Int64(samples.count)
    }

    /// In the microphone + system mode the main meter shows the microphone and a second
    /// meter the system audio; with system audio only, the main meter shows the system audio.
    private static func yieldLevel(microphone: Float?, system: Float, state: inout State) {
        let recordedTime = Double(state.framesWritten) / AudioFormat.sampleRate
        state.levels?.yield(AudioLevel(
            rms: microphone ?? system,
            systemRMS: microphone == nil ? nil : system,
            recordedTime: recordedTime,
            hasReceivedSystemAudio: state.hasReceivedSystemAudio
        ))
    }

    private static func rms(of samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return vDSP.rootMeanSquare(samples)
    }
}
