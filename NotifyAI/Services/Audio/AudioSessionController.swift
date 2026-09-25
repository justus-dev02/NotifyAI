//
//  AudioSessionController.swift
//  NotifyAI
//

import AVFoundation
import OSLog

/// Configures the shared audio session on iOS and reports interruptions such as phone calls.
/// macOS has no audio session, so all methods are no-ops there.
@MainActor
final class AudioSessionController {
    enum Interruption: Sendable {
        case began
        case ended(shouldResume: Bool)
    }

    /// Called on the main actor when the system interrupts or releases the session.
    var onInterruption: ((Interruption) -> Void)?

    #if os(iOS)
    private var observer: (any NSObjectProtocol)?
    private let logger = Logger.audio

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            // Extract plain values before crossing into the main actor.
            let info = notification.userInfo
            let typeValue = info?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = info?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleInterruption(typeValue: typeValue, optionsValue: optionsValue)
            }
        }
    }

    func activateForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        // `.default` keeps automatic gain control, which helps with quiet speakers far away.
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try session.setActive(true)
    }

    func activateForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
    }

    func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            logger.debug("Deactivating the audio session failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleInterruption(typeValue: UInt?, optionsValue: UInt?) {
        guard let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            onInterruption?(.began)
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)
            onInterruption?(.ended(shouldResume: options.contains(.shouldResume)))
        @unknown default:
            break
        }
    }
    #else
    func activateForRecording() throws {}
    func activateForPlayback() throws {}
    func deactivate() {}
    #endif
}
