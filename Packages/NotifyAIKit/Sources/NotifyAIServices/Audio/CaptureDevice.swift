//
//  CaptureDevice.swift
//  NotifyAIServices
//

import AudioCapture
import Foundation
import NotifyAICore

/// Where the audio of a recording comes from. Both kinds feed the same
/// `AudioCaptureContext`; `AudioRecorder` drives them without knowing which one runs.
///
/// - `MicrophoneDevice`: the microphone through `AVAudioEngine` (iOS and macOS).
/// - `SystemAudioDevice`: microphone + system audio, or system audio only, through a Core
///   Audio process tap (macOS only).
@MainActor
protocol CaptureDevice: AnyObject {
    /// Starts delivering audio into the capture context.
    func start() async throws
    /// Tells the device whether writing is paused; a device restarted after a change stays
    /// stopped while paused.
    func setPaused(_ paused: Bool)
    /// Restarts whatever the system stopped (a phone call, sleep, a rebuild that failed).
    /// - Throws: When the device cannot be started; nothing is recorded then.
    func resumeIfStopped() async throws
    func stop() async
}

/// Creates the device for a configuration. The only place that knows which platform can
/// record which source.
@MainActor
enum CaptureDevices {
    static func make(for configuration: CaptureConfiguration, capture: AudioCaptureContext) throws -> any CaptureDevice {
        switch configuration.source {
        case .microphone:
            return MicrophoneDevice(capture: capture)
        case .microphoneAndSystemAudio, .systemAudio:
            #if os(macOS)
            return try SystemAudioDevice(configuration: configuration, capture: capture)
            #else
            throw AudioRecorderError.systemAudioUnavailable
            #endif
        }
    }
}
