//
//  AudioRecorder.swift
//  NotifyAIServices
//

import AudioCapture
import AVFoundation
import NotifyAICore
import NotifyAIPersistence
import OSLog

/// What to record.
public struct CaptureConfiguration: Sendable {
    var source: RecordingAudioSource = .microphone
    var systemAudioTarget: SystemAudioTarget = .allApps
}

/// The streams a running recording produces.
public struct AudioCaptureStreams: Sendable {
    /// Every converted block, in order and without gaps, for live transcription; `nil` when
    /// the recording is not transcribed live. Unbounded so transcription never loses audio;
    /// `LiveTranscriptFeed` limits how far it may fall behind.
    let chunks: AsyncStream<AudioChunk>?
    /// Level updates for metering. Only the newest value is kept.
    let levels: AsyncStream<AudioLevel>
    /// Failures and warnings of the running capture (full disk).
    let events: AsyncStream<CaptureEvent>
}

enum AudioRecorderError: LocalizedError {
    case alreadyRecording
    case noInputDevice
    case converterUnavailable
    case engineStartFailed(any Error)
    case fileCreationFailed(any Error)
    case systemAudioUnavailable
    case insufficientStorage(availableBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            String(localized: "Es läuft bereits eine Aufnahme.", bundle: .module)
        case .noInputDevice:
            String(localized: "Es wurde kein Mikrofon gefunden.", bundle: .module)
        case .converterUnavailable:
            String(localized: "Das Audioformat des Mikrofons wird nicht unterstützt.", bundle: .module)
        case .engineStartFailed(let error):
            String(localized: "Die Aufnahme konnte nicht gestartet werden: \(error.localizedDescription)", bundle: .module)
        case .fileCreationFailed(let error):
            String(localized: "Die Audiodatei konnte nicht angelegt werden: \(error.localizedDescription)", bundle: .module)
        case .systemAudioUnavailable:
            String(localized: "Systemton kann auf diesem Gerät nicht aufgenommen werden.", bundle: .module)
        case .insufficientStorage(let availableBytes):
            String(localized: "Nicht genügend freier Speicherplatz (\(TimeFormatting.byteCount(availableBytes)) frei). Für eine Aufnahme werden mindestens \(TimeFormatting.byteCount(AudioRecorder.minimumFreeBytesToStart)) benötigt.", bundle: .module)
        }
    }
}

/// Captures audio, converts it to 16 kHz mono, writes it to disk and streams it to live
/// transcription.
///
/// The audio comes from a `CaptureDevice`: the microphone through `AVAudioEngine`, or a Core
/// Audio process tap for system audio (macOS). Both feed the same `AudioCaptureContext`, so
/// the recorder itself does not depend on the platform.
///
/// Threading: the public API is main-actor isolated. The audio threads only write into the
/// lock-free rings of a capture input; `AudioCaptureContext` processes them on its own
/// queue. Time is measured in recorded samples, so it excludes pauses and matches the audio
/// file exactly.
///
/// Device failures: when a device cannot be restarted after a change (microphone
/// disconnected, aggregate device could not be rebuilt), the recorder does not pause on its
/// own. It reports `CaptureEvent.inputFailed` through the event stream, and the recording
/// controller, which owns the recording's state, pauses and tells the user.
@MainActor
final class AudioRecorder: AudioRecording {
    /// A recording does not start with less free space: about 14 MB per hour of audio plus
    /// transcript, index and the processing of a long recording.
    nonisolated static let minimumFreeBytesToStart: Int64 = 200 * 1_024 * 1_024

    private let capture = AudioCaptureContext()
    private let logger = Logger.audio
    private var device: (any CaptureDevice)?

    private var isRunning: Bool { device != nil }
    /// Whether writing is paused. Tracked here, so the main actor never waits for the
    /// capture's lock.
    private(set) var isPaused = false

    /// Recorded time so far, excluding pauses.
    var recordedTime: TimeInterval { capture.recordedTime }

    /// Starts recording into a new file at `url`.
    /// - Parameter streamsAudio: Whether the audio is streamed for live transcription.
    func start(
        writingTo url: URL,
        configuration: CaptureConfiguration = CaptureConfiguration(),
        streamsAudio: Bool = true
    ) async throws -> AudioCaptureStreams {
        guard !isRunning else { throw AudioRecorderError.alreadyRecording }
        let directory = url.deletingLastPathComponent()
        if let available = StorageLocations.availableCapacity(at: directory), available < Self.minimumFreeBytesToStart {
            throw AudioRecorderError.insufficientStorage(availableBytes: available)
        }
        let device = try CaptureDevices.make(for: configuration, capture: capture)

        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: AudioFormat.recordingFileSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw AudioRecorderError.fileCreationFailed(error)
        }

        var chunks: AsyncStream<AudioChunk>?
        var chunkContinuation: AsyncStream<AudioChunk>.Continuation?
        if streamsAudio {
            let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
            chunks = stream
            chunkContinuation = continuation
        }
        let (levels, levelContinuation) = AsyncStream.makeStream(of: AudioLevel.self, bufferingPolicy: .bufferingNewest(1))
        let (events, eventContinuation) = AsyncStream.makeStream(of: CaptureEvent.self)
        capture.begin(
            sink: file,
            chunks: chunkContinuation,
            levels: levelContinuation,
            events: eventContinuation,
            recordsSourceActivity: configuration.source == .microphoneAndSystemAudio,
            storageDirectory: directory
        )

        do {
            try await device.start()
        } catch {
            await capture.finish()
            throw error
        }
        self.device = device
        isPaused = false
        logger.info("Recording started (\(configuration.source.rawValue, privacy: .public))")
        return AudioCaptureStreams(chunks: chunks, levels: levels, events: events)
    }

    /// Stops writing audio. The devices keep running so the level meter stays live.
    func pause() {
        guard let device else { return }
        isPaused = true
        device.setPaused(true)
        capture.setPaused(true)
    }

    /// Resumes writing once the devices run again. Writing resumes only after every device
    /// is confirmed running. If that fails, the recording stays paused and the error is thrown.
    func resume() async throws {
        guard let device else { return }
        try await device.resumeIfStopped()
        // The recording may have been stopped while the devices were restarted.
        guard isRunning else { return }
        device.setPaused(false)
        capture.setPaused(false)
        isPaused = false
    }

    /// Publishes levels only once per second while no meter is visible.
    func setReducedLevelUpdates(_ reduced: Bool) {
        capture.setReducedLevelUpdates(reduced)
    }

    /// Ends the audio stream for live transcription; the file is still written.
    func stopStreamingAudio() {
        capture.stopStreamingChunks()
    }

    /// Stops the recording, finalizes the file and finishes both streams.
    @discardableResult
    func stop() async -> RecordingResult {
        guard let device else { return RecordingResult(duration: capture.recordedTime, sourceActivity: nil) }
        self.device = nil
        isPaused = false
        await device.stop()
        let result = await capture.finish()
        logger.info("Recording stopped after \(result.duration, format: .fixed(precision: 1)) s")
        return result
    }
}
