//
//  RecordingSettings.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore
import Observation

/// What new recordings capture: microphone and/or system audio, and from which app.
@MainActor
@Observable
public final class RecordingSettings {
    private enum Key {
        static let audioSource = "recording.audioSource"
        static let systemAudioTarget = "recording.systemAudioTarget"
        static let echoCancellation = "recording.echoCancellation"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Always `.microphone` where system audio is unavailable (iOS).
    public var audioSource: RecordingAudioSource {
        didSet { defaults.set(audioSource.rawValue, forKey: Key.audioSource) }
    }

    /// Whose audio "Systemton" recordings capture.
    public var systemAudioTarget: SystemAudioTarget {
        didSet { defaults.set(try? JSONEncoder().encode(systemAudioTarget), forKey: Key.systemAudioTarget) }
    }

    /// Removes the echo of the system audio from the microphone in "Mikrofon + Systemton"
    /// recordings, for meetings without headphones.
    public var echoCancellation: Bool {
        didSet { defaults.set(echoCancellation, forKey: Key.echoCancellation) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        audioSource = defaults.string(forKey: Key.audioSource)
            .flatMap(RecordingAudioSource.init(rawValue:))
            .flatMap { RecordingAudioSource.available.contains($0) ? $0 : nil } ?? .microphone
        systemAudioTarget = defaults.data(forKey: Key.systemAudioTarget)
            .flatMap { try? JSONDecoder().decode(SystemAudioTarget.self, from: $0) } ?? .allApps
        echoCancellation = defaults.object(forKey: Key.echoCancellation) as? Bool ?? true
    }

    var captureConfiguration: CaptureConfiguration {
        CaptureConfiguration(source: audioSource, systemAudioTarget: systemAudioTarget, cancelsEcho: echoCancellation)
    }
}
