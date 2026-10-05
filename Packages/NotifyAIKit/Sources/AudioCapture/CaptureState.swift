//
//  CaptureState.swift
//  AudioCapture
//

import Accelerate
import AVFoundation
import NotifyAICore
import OSLog
import Synchronization

/// The number of frames on the recording timeline, readable without a lock.
final class FrameCounter: Sendable {
    let frames = Atomic<Int>(0)
}

/// A mixed block of 16 kHz mono samples, waiting to be written.
struct MixedBlock: Sendable {
    let samples: [Float]
    let startFrame: Int64
}

/// Conversion, mixing and metering: the state behind `AudioCaptureContext`'s state lock.
/// Never held while touching the disk; everything here is pure computation.
struct CaptureState {
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

extension CaptureState {
    /// Converts everything the rings hold. While paused the audio is converted anyway (the
    /// resamplers keep their state, so resuming does not click) and then discarded.
    mutating func drain() {
        microphone?.drain(into: &pendingMicrophone)
        system?.drain(into: &pendingSystem)

        guard isPaused || hasFailed else { return }
        let discarded = recordsMicrophone ? pendingMicrophone.count : pendingSystem.count
        pendingMicrophone.removeAll()
        pendingSystem.removeAll()
        pausedSamples += discarded
        while pausedSamples >= AudioCaptureContext.blockSize {
            pausedSamples -= AudioCaptureContext.blockSize
            yieldLevel(microphone: recordsMicrophone ? 0 : nil, system: recordsSystem ? 0 : nil)
        }
    }

    /// Mixes complete blocks, or everything when `force` is set, and hands them to the writer.
    mutating func flush(force: Bool) {
        guard !hasFailed else { return }
        if force {
            alignPending()
        }
        while true {
            let available: Int = switch (recordsMicrophone, recordsSystem) {
            case (true, true): min(pendingMicrophone.count, pendingSystem.count)
            case (true, false): pendingMicrophone.count
            case (false, true): pendingSystem.count
            case (false, false): 0
            }
            guard available > 0, force || available >= AudioCaptureContext.blockSize else { return }
            let count = min(available, force ? AudioCaptureContext.writeCapacity : AudioCaptureContext.blockSize)
            let microphoneSamples = recordsMicrophone ? pendingMicrophone.prefix(count) : nil
            let systemSamples = recordsSystem ? pendingSystem.prefix(count) : nil

            if let systemSamples, !hasReceivedSystemAudio, vDSP.maximumMagnitude(systemSamples) > 0 {
                // A denied permission delivers digital silence, so this is the only sign of success.
                hasReceivedSystemAudio = true
            }
            let mixed: [Float] = if let microphoneSamples, let systemSamples {
                AudioCaptureContext.mix(microphoneSamples, systemSamples)
            } else {
                Array(microphoneSamples ?? systemSamples ?? [])
            }
            if let microphoneSamples, let systemSamples {
                activity?.append(microphone: microphoneSamples, system: systemSamples, startFrame: framesProduced)
            }
            blocks.append(MixedBlock(samples: mixed, startFrame: framesProduced))
            framesProduced += Int64(mixed.count)
            counter.frames.store(Int(framesProduced), ordering: .relaxed)
            yieldLevel(
                microphone: microphoneSamples.map { Self.rms(of: $0) },
                system: systemSamples.map { Self.rms(of: $0) }
            )

            if recordsMicrophone { pendingMicrophone.removeFirst(count) }
            if recordsSystem { pendingSystem.removeFirst(count) }
        }
    }

    /// Pads the shorter pending source with silence so both have the same length.
    mutating func alignPending() {
        guard recordsMicrophone, recordsSystem else { return }
        let difference = pendingSystem.count - pendingMicrophone.count
        if difference > 0 {
            pendingMicrophone.appendSilence(difference)
        } else {
            pendingSystem.appendSilence(-difference)
        }
    }

    /// In the microphone + system mode the main meter shows the microphone and a second
    /// meter the system audio; with system audio only, the main meter shows the system audio.
    mutating func yieldLevel(microphone microphoneLevel: Float?, system systemLevel: Float?) {
        blocksSinceLevelUpdate += 1
        guard blocksSinceLevelUpdate >= levelInterval else { return }
        blocksSinceLevelUpdate = 0
        let recordedTime = Double(framesProduced) / AudioFormat.sampleRate
        levels?.yield(AudioLevel(
            rms: microphoneLevel ?? systemLevel ?? 0,
            systemRMS: microphoneLevel == nil ? nil : systemLevel,
            recordedTime: recordedTime,
            hasReceivedSystemAudio: hasReceivedSystemAudio
        ))
    }

    static func rms(of samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return vDSP.rootMeanSquare(samples)
    }

    /// Collects the audio the sources lost (full rings, failed conversions) and logs it, at
    /// most every `AudioCaptureContext.lossReportInterval` unless `force` is set. Nothing is
    /// lost silently, and a persistent problem does not flood the log.
    mutating func reportLosses(force: Bool) {
        if let losses = microphone?.takeLosses() {
            unreportedMicrophoneLosses.add(losses)
        }
        if let losses = system?.takeLosses() {
            unreportedSystemLosses.add(losses)
        }
        let microphoneLosses = unreportedMicrophoneLosses
        let systemLosses = unreportedSystemLosses
        guard !microphoneLosses.isEmpty || !systemLosses.isEmpty,
              force || ContinuousClock.now - lastLossReport >= AudioCaptureContext.lossReportInterval
        else { return }
        lastLossReport = .now
        unreportedMicrophoneLosses = SampleLosses()
        unreportedSystemLosses = SampleLosses()

        if microphoneLosses.dropped > 0 || systemLosses.dropped > 0 {
            Logger.capture.error("Capture processing fell behind; dropped \(microphoneLosses.dropped, privacy: .public) microphone and \(systemLosses.dropped, privacy: .public) system samples")
        }
        if microphoneLosses.failedConversion > 0 || systemLosses.failedConversion > 0 {
            let reason = microphoneLosses.conversionError ?? systemLosses.conversionError ?? "unknown"
            Logger.capture.error("Converting captured audio failed (\(reason, privacy: .public)); lost \(microphoneLosses.failedConversion, privacy: .public) microphone and \(systemLosses.failedConversion, privacy: .public) system samples")
        }
    }
}
