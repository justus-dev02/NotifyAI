//
//  SystemAudioDevice.swift
//  NotifyAIServices
//

#if os(macOS)
import AudioCapture
import Foundation
import NotifyAICore

/// Microphone + system audio, or system audio only, through a Core Audio process tap in a
/// private aggregate device (`SystemAudioCapture`).
@MainActor
final class SystemAudioDevice: CaptureDevice {
    private let session: SystemAudioCapture

    init(configuration: CaptureConfiguration, capture: AudioCaptureContext) throws {
        session = SystemAudioCapture(
            includesMicrophone: configuration.source.usesMicrophone,
            target: try Self.resolve(configuration.systemAudioTarget),
            capture: capture
        )
    }

    func start() async throws {
        try await session.start()
    }

    func setPaused(_ paused: Bool) {}

    /// Rebuilds the aggregate device if it stopped while the Mac was asleep or could not be
    /// rebuilt after a change.
    func resumeIfStopped() async throws {
        try await session.restartIfStopped()
    }

    func stop() async {
        await session.stop()
    }

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
}
#endif
