//
//  RecordingMeter.swift
//  NotifyAI
//

import Foundation
import Observation

/// Recorded time and level history of the running recording, for the meters.
///
/// Updated about ten times per second. Kept apart from `RecordingController` so that only
/// views that draw meters or the timer observe these frequent changes.
@MainActor
@Observable
final class RecordingMeter {
    static let historyLength = 48

    /// Recorded time, pauses excluded.
    private(set) var elapsed: TimeInterval = 0
    /// Recent microphone levels (0…1), oldest first.
    private(set) var levels = RecordingMeter.silence
    /// Recent system audio levels while it is recorded together with the microphone.
    private(set) var systemLevels = RecordingMeter.silence
    /// Whether any non-silent system audio arrived so far.
    private(set) var hasReceivedSystemAudio = false

    func record(_ level: AudioLevel) {
        elapsed = level.recordedTime
        levels.removeFirst()
        levels.append(Self.meterValue(level.rms))
        if let systemRMS = level.systemRMS {
            systemLevels.removeFirst()
            systemLevels.append(Self.meterValue(systemRMS))
        }
        if level.hasReceivedSystemAudio, !hasReceivedSystemAudio {
            hasReceivedSystemAudio = true
        }
    }

    func reset() {
        elapsed = 0
        levels = Self.silence
        systemLevels = Self.silence
        hasReceivedSystemAudio = false
    }

    private static let silence = [Float](repeating: 0, count: historyLength)

    /// Perceptual scaling: speech RMS is typically 0.01–0.3.
    static func meterValue(_ rms: Float) -> Float {
        min(1, max(0, (20 * log10(max(rms, 1e-4)) + 50) / 50))
    }
}
