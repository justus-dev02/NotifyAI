//
//  InterruptionPolicy.swift
//  NotifyAIServices
//

import Foundation

/// Decides how system interruptions (a phone call, Siri) affect the recording.
///
/// Only an interruption that paused a running recording may resume it when it ends. A pause
/// the user chose stays a pause: an interruption that begins while paused changes nothing,
/// and once the user pauses or resumes during an interruption, the recording is theirs again.
struct InterruptionPolicy {
    enum Action: Equatable {
        case none
        case pause
        case resume
    }

    /// Whether the current pause was caused by an interruption.
    private(set) var isPausedByInterruption = false

    mutating func interruptionBegan(isRecording: Bool) -> Action {
        guard isRecording else { return .none }
        isPausedByInterruption = true
        return .pause
    }

    mutating func interruptionEnded(shouldResume: Bool, isPaused: Bool) -> Action {
        guard isPausedByInterruption else { return .none }
        isPausedByInterruption = false
        return shouldResume && isPaused ? .resume : .none
    }

    /// The user paused or resumed, or a failed device paused the recording: the end of the
    /// interruption must not resume it.
    mutating func userTookOver() {
        isPausedByInterruption = false
    }
}
