//
//  MicrophoneDevice.swift
//  NotifyAIServices
//

import AudioCapture
import AVFoundation
import NotifyAICore
import OSLog

/// The microphone through `AVAudioEngine`.
///
/// When the input device or its format changes (headset plugged in, other microphone chosen
/// on the Mac), the engine stops; the tap is rebuilt for the new format. If that fails, the
/// device does not pause on its own: it reports `CaptureEvent.inputFailed` through the capture
/// context, and the recording controller, which owns the recording's state, pauses and tells
/// the user. `resumeIfStopped()` retries.
@MainActor
final class MicrophoneDevice: CaptureDevice {
    private let engine = AVAudioEngine()
    private let capture: AudioCaptureContext
    private let logger = Logger.audio
    private var configurationObserver: (any NSObjectProtocol)?
    /// The input tap could not be rebuilt after a configuration change; `resumeIfStopped()` retries.
    private var needsInputRebuild = false
    private var isPaused = false
    private var isRunning = false

    init(capture: AudioCaptureContext) {
        self.capture = capture
    }

    func start() async throws {
        do {
            try installInputTap()
            engine.prepare()
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw (error as? AudioRecorderError) ?? AudioRecorderError.engineStartFailed(error)
        }
        isRunning = true
        observeConfigurationChanges()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    /// Restarts the engine if the system stopped it (e.g. after a phone call) or its input
    /// could not be rebuilt.
    func resumeIfStopped() async throws {
        guard isRunning, needsInputRebuild || !engine.isRunning else { return }
        do {
            if needsInputRebuild {
                try installInputTap()
                needsInputRebuild = false
            }
            engine.prepare()
            try engine.start()
        } catch {
            throw (error as? AudioRecorderError) ?? AudioRecorderError.engineStartFailed(error)
        }
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        needsInputRebuild = false
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
    nonisolated private static func makeTapBlock(for input: MicrophoneCaptureInput) -> AVAudioNodeTapBlock {
        { buffer, _ in input.process(buffer) }
    }

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

    /// The engine has stopped; rebuild the tap for the new format. While paused, the engine
    /// is started by `resumeIfStopped()`.
    private func handleConfigurationChange() {
        guard isRunning else { return }
        logger.info("Audio configuration changed, rebuilding input tap")
        do {
            do {
                try installInputTap()
            } catch {
                needsInputRebuild = true
                throw error
            }
            if !isPaused {
                engine.prepare()
                try engine.start()
            }
        } catch {
            let reason = ((error as? AudioRecorderError) ?? AudioRecorderError.engineStartFailed(error)).localizedDescription
            logger.error("Restarting after a configuration change failed: \(error.localizedDescription, privacy: .public)")
            capture.reportInputFailure(reason)
        }
    }
}
