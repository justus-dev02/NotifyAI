//
//  AudioRecorder.swift
//  NotifyAI
//

import AVFoundation
import OSLog

/// A level reading for the UI.
struct AudioLevel: Sendable {
    /// Root mean square of the last block, 0…1: the microphone, or the system audio when
    /// only system audio is recorded.
    let rms: Float
    /// System audio level while it is recorded together with the microphone.
    let systemRMS: Float?
    /// Recorded time so far (pauses excluded).
    let recordedTime: TimeInterval
    /// Whether any non-silent system audio arrived so far.
    let hasReceivedSystemAudio: Bool
}

/// What to record.
struct CaptureConfiguration: Sendable {
    var source: RecordingAudioSource = .microphone
    var systemAudioTarget: SystemAudioTarget = .allApps
}

/// The outcome of a finished recording.
struct RecordingResult: Sendable {
    /// Recorded seconds, pauses excluded.
    let duration: TimeInterval
    /// Levels of microphone and system audio; only for microphone + system audio recordings.
    let sourceActivity: SourceActivity?
}

/// The two streams a running recording produces.
struct AudioCaptureStreams: Sendable {
    /// Every converted buffer, in order and without gaps. Unbounded so transcription never loses audio.
    let chunks: AsyncStream<AudioChunk>
    /// Level updates for metering. Only the newest value is kept.
    let levels: AsyncStream<AudioLevel>
}

enum AudioRecorderError: LocalizedError {
    case alreadyRecording
    case noInputDevice
    case converterUnavailable
    case engineStartFailed(any Error)
    case fileCreationFailed(any Error)
    case systemAudioUnavailable

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            "Es läuft bereits eine Aufnahme."
        case .noInputDevice:
            "Es wurde kein Mikrofon gefunden."
        case .converterUnavailable:
            "Das Audioformat des Mikrofons wird nicht unterstützt."
        case .engineStartFailed(let error):
            "Die Aufnahme konnte nicht gestartet werden: \(error.localizedDescription)"
        case .fileCreationFailed(let error):
            "Die Audiodatei konnte nicht angelegt werden: \(error.localizedDescription)"
        case .systemAudioUnavailable:
            "Systemton kann auf diesem Gerät nicht aufgenommen werden."
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
/// Threading: the public API is main-actor isolated. Audio callbacks only touch shared
/// state through `AudioCaptureContext`, which is protected by a mutex. Time is measured in
/// written samples, so it excludes pauses and matches the audio file exactly.
@MainActor
final class AudioRecorder {
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

    func start(writingTo url: URL, configuration: CaptureConfiguration = CaptureConfiguration()) async throws -> AudioCaptureStreams {
        guard !isRunning else { throw AudioRecorderError.alreadyRecording }

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

        let (chunks, chunkContinuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
        let (levels, levelContinuation) = AsyncStream.makeStream(of: AudioLevel.self, bufferingPolicy: .bufferingNewest(1))
        capture.begin(
            file: file,
            chunks: chunkContinuation,
            levels: levelContinuation,
            recordsSourceActivity: configuration.source == .microphoneAndSystemAudio
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
        return AudioCaptureStreams(chunks: chunks, levels: levels)
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

    /// Resumes writing. Restarts the engine if the system stopped it (e.g. after a phone call).
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
        let outputFormat = AudioFormat.makeProcessingFormat()
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioRecorderError.converterUnavailable
        }
        // Mix all input channels instead of silently using only the first one.
        converter.downmix = true
        capture.setEngineConverter(converter)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: Self.makeTapBlock(for: capture))
    }

    /// Built in a nonisolated context: a closure created inside a main-actor method would
    /// inherit main-actor isolation and trap when Core Audio calls it on its own thread.
    private nonisolated static func makeTapBlock(for capture: AudioCaptureContext) -> AVAudioNodeTapBlock {
        { buffer, _ in capture.process(buffer) }
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
