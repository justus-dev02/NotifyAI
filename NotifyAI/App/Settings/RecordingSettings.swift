//
//  RecordingSettings.swift
//  NotifyAI
//

import Foundation
import Observation

/// What new recordings capture: microphone and/or system audio, and from which app.
@MainActor
@Observable
final class RecordingSettings {
    private enum Key {
        static let audioSource = "recording.audioSource"
        static let systemAudioTarget = "recording.systemAudioTarget"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Always `.microphone` where system audio is unavailable (iOS).
    var audioSource: RecordingAudioSource {
        didSet { defaults.set(audioSource.rawValue, forKey: Key.audioSource) }
    }

    /// Whose audio "Systemton" recordings capture.
    var systemAudioTarget: SystemAudioTarget {
        didSet { defaults.set(try? JSONEncoder().encode(systemAudioTarget), forKey: Key.systemAudioTarget) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        audioSource = defaults.string(forKey: Key.audioSource)
            .flatMap(RecordingAudioSource.init(rawValue:))
            .flatMap { RecordingAudioSource.available.contains($0) ? $0 : nil } ?? .microphone
        systemAudioTarget = defaults.data(forKey: Key.systemAudioTarget)
            .flatMap { try? JSONDecoder().decode(SystemAudioTarget.self, from: $0) } ?? .allApps
    }

    var captureConfiguration: CaptureConfiguration {
        CaptureConfiguration(source: audioSource, systemAudioTarget: systemAudioTarget)
    }
}
