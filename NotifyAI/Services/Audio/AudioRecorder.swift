//
//  AudioRecorder.swift
//  NotifyAI
//

import AudioCapture
import AVFoundation
import NotifyAICore
import OSLog

/// What to record.
struct CaptureConfiguration: Sendable {
    var source: RecordingAudioSource = .microphone
    var systemAudioTarget: SystemAudioTarget = .allApps
}

/// The streams a running recording produces.
struct AudioCaptureStreams: Sendable {
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
            String(localized: "Es läuft bereits eine Aufnahme.")
        case .noInputDevice:
            String(localized: "Es wurde kein Mikrofon gefunden.")
        case .converterUnavailable:
            String(localized: "Das Audioformat des Mikrofons wird nicht unterstützt.")
        case .engineStartFailed(let error):
            String(localized: "Die Aufnahme konnte nicht gestartet werden: \(error.localizedDescription)")
        case .fileCreationFailed(let error):
            String(localized: "Die Audiodatei konnte nicht angelegt werden: \(error.localizedDescription)")
        case .systemAudioUnavailable:
            String(localized: "Systemton kann auf diesem Gerät nicht aufgenommen werden.")
        case .insufficientStorage(let availableBytes):
            String(localized: "Nicht genügend freier Speicherplatz (\(TimeFormatting.byteCount(availableBytes)) frei). Für eine Aufnahme werden mindestens \(TimeFormatting.byteCount(AudioRecorder.minimumFreeBytesToStart)) benötigt.")
        }
    }
}

/// Captures audio, converts it to 16 kHz mono, writes it to disk and streams it to live
/// transcription.
///
/// Two capture paths feed the same `AudioCaptureContext`:
/// - Microphone only: `AVAudioEngine` (iOS and macOS).
/// - Microphone + system audio, or system audio only: a Core Audio process tap in a private
///   aggregate device (`SystemAudioCapture`, macOS only).
///
/// Threading: the public API is main-actor isolated. The audio threads only write into the
/// lock-free rings of a capture input; `AudioCaptureContext` processes them on its own
/// queue. Time is measured in written samples, so it excludes pauses and matches the audio
/// file exactly.
@MainActor
final class AudioRecorder {
    /// A recording does not start with less free space: about 14 MB per hour of audio plus
    /// transcript, index and the processing of a long recording.
    nonisolated static let minimumFreeBytesToStart: Int64 = 200 * 1_024 * 1_024

    private let engine = AVAudioEngine()
    private let capture = AudioCaptureContext()
    private let logger = Logger.audio
    private var configurationObserver: (any NSObjectProtocol)?
    #if os(macOS)
    private var systemAudio: SystemAudioCapture?
    #endif

    private(set) var isRunning = false

    /// Recorded time so far, excluding pauses.
    var recordedTime: TimeInterval { capture.recordedTime }

    var isPaused: Bool { capture.isPaused }

    /// Whether the running recording uses `AVAudioEngine` (microphone only).
    private var usesEngine: Bool {
        #if os(macOS)
        systemAudio == nil
        #else
        true
        #endif
    }

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

        switch configuration.source {
        case .microphone:
            do {
                try installInputTap()
                engine.prepare()
                try engine.start()
            } catch {
                engine.inputNode.removeTap(onBus: 0)
                capture.finish()
                throw (error as? AudioRecorderError) ?? AudioRecorderError.engineStartFailed(error)
            }
            observeConfigurationChanges()

        case .microphoneAndSystemAudio, .systemAudio:
            #if os(macOS)
            let session: SystemAudioCapture
            do {
                session = SystemAudioCapture(
                    includesMicrophone: configuration.source.usesMicrophone,
                    target: try Self.resolve(configuration.systemAudioTarget),
                    capture: capture
                )
                try await session.start()
            } catch {
                capture.finish()
                throw error
            }
            systemAudio = session
            #else
            capture.finish()
            throw AudioRecorderError.systemAudioUnavailable
            #endif
        }

        isRunning = true
        logger.info("Recording started (\(configuration.source.rawValue, privacy: .public))")
        return AudioCaptureStreams(chunks: chunks, levels: levels, events: events)
    }

    #if os(macOS)
    /// Looks up where the chosen app is installed; its helper processes live inside the bundle.
    private static func resolve(_ target: SystemAudioTarget) throws -> SystemAudioCapture.Target {
        switch target {
        case .allApps:
            return .allApps
        case .app(let bundleID, let name):
            guard let app = AudioAppCatalog.runningApplication(bundleID: bundleID) else {
                throw SystemAudioError.appNotRunning(name)
            }
            return .app(bundleID: bundleID, bundlePath: app.bundleURL?.path)
        }
    }
    #endif

    /// Stops writing audio. The engine keeps running so the level meter stays live.
    func pause() {
        capture.setPaused(true)
    }

    /// Resumes writing. Restarts the engine if the system stopped it (e.g. after a phone
    /// call), or the aggregate device if it stopped while the Mac was asleep.
    func resume() throws {
        capture.setPaused(false)
        if isRunning, usesEngine, !engine.isRunning {
            do {
                try engine.start()
            } catch {
                capture.setPaused(true)
                throw AudioRecorderError.engineStartFailed(error)
            }
        }
        #if os(macOS)
        if let systemAudio {
            Task { await systemAudio.restartIfStopped() }
        }
        #endif
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
        guard isRunning else { return RecordingResult(duration: capture.recordedTime, sourceActivity: nil) }
        let usedEngine = usesEngine
        #if os(macOS)
        if let systemAudio {
            await systemAudio.stop()
            self.systemAudio = nil
        }
        #endif
        if usedEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        isRunning = false
        let result = capture.finish()
        logger.info("Recording stopped after \(result.duration, format: .fixed(precision: 1)) s")
        return result
    }

    // MARK: - Private

    private func installInputTap() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }
        // The old tap is removed first, so nothing writes into the previous ring while its
        // last samples are processed. All input channels are mixed, not just the first one.
        input.removeTap(onBus: 0)
        let captureInput = try capture.configureMicrophone(format: inputFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: Self.makeTapBlock(for: captureInput))
    }

    /// Built in a nonisolated context: a closure created inside a main-actor method would
    /// inherit main-actor isolation and trap when Core Audio calls it on its own thread.
    private nonisolated static func makeTapBlock(for input: MicrophoneCaptureInput) -> AVAudioNodeTapBlock {
        { buffer, _ in input.process(buffer) }
    }

    /// The input device or its format changed (headset plugged in, other microphone
    /// selected on the Mac). The engine has stopped; rebuild the tap for the new format.
    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleConfigurationChange()
            }
        }
    }

    private func handleConfigurationChange() {
        guard isRunning else { return }
        logger.info("Audio configuration changed, rebuilding input tap")
        do {
            try installInputTap()
            if !capture.isPaused {
                try engine.start()
            }
        } catch {
            logger.error("Restarting after a configuration change failed: \(error.localizedDescription, privacy: .public)")
            capture.setPaused(true)
        }
    }
}
