//
//  RecordingMeter.swift
//  NotifyAI
//

import AudioCapture
import Foundation
import Observation

/// Recorded time and level history of the running recording, for the meters.
///
/// Levels arrive ten times per second while a meter is visible and once per second
/// otherwise. Views observe only what they draw: the time displays read `elapsedSeconds`,
/// which changes once per second, so the menu bar item and the timers are not re-rendered
/// ten times per second. Kept apart from `RecordingController` for the same reason.
@MainActor
@Observable
final class RecordingMeter {
    static let historyLength = 48

    /// Whole recorded seconds, pauses excluded. Changes once per second.
    private(set) var elapsedSeconds = 0
    /// Recent microphone levels (0…1), oldest first. Only updated while shown.
    private(set) var levels = RecordingMeter.silence
    /// Recent system audio levels while it is recorded together with the microphone.
    private(set) var systemLevels = RecordingMeter.silence
    /// Whether any non-silent system audio arrived so far.
    private(set) var hasReceivedSystemAudio = false

    /// Recorded time with sub-second precision. Not observed: it changes with every level.
    @ObservationIgnored private(set) var elapsed: TimeInterval = 0
    /// Whether a level meter is on screen; otherwise level readings only update the time.
    @ObservationIgnored var showsLevels = true

    func record(_ level: AudioLevel) {
        elapsed = level.recordedTime
        let seconds = Int(level.recordedTime)
        if seconds != elapsedSeconds {
            elapsedSeconds = seconds
        }
        if showsLevels {
            levels.removeFirst()
            levels.append(Self.meterValue(level.rms))
            if let systemRMS = level.systemRMS {
                systemLevels.removeFirst()
                systemLevels.append(Self.meterValue(systemRMS))
            }
        }
        if level.hasReceivedSystemAudio, !hasReceivedSystemAudio {
            hasReceivedSystemAudio = true
        }
    }

    func reset() {
        elapsed = 0
        elapsedSeconds = 0
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
