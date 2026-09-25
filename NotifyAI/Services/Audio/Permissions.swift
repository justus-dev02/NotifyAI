//
//  Permissions.swift
//  NotifyAI
//

import AVFoundation
import Speech

/// Authorization state of a system permission.
enum PermissionState: Sendable {
    case notDetermined
    case granted
    case denied
}

enum MicrophonePermission {
    static var state: PermissionState {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        case .undetermined: .notDetermined
        @unknown default: .denied
        }
    }

    /// Asks for access if needed. Returns whether recording is allowed.
    static func request() async -> Bool {
        switch state {
        case .granted: true
        case .denied: false
        case .notDetermined: await AVAudioApplication.requestRecordPermission()
        }
    }
}

enum SpeechRecognitionPermission {
    static var state: PermissionState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    /// Asks for speech recognition access if it has not been decided yet.
    @discardableResult
    static func request() async -> PermissionState {
        guard state == .notDetermined else { return state }
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            // Explicitly `@Sendable`: the callback arrives on an arbitrary queue and must not
            // inherit the caller's actor isolation.
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
        return status == .authorized ? .granted : .denied
    }
}
