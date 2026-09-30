//
//  CaptureTypes.swift
//  AudioCapture
//

import Foundation
import NotifyAICore

/// A level reading for the UI.
public struct AudioLevel: Sendable {
    /// Root mean square of the last block, 0…1: the microphone, or the system audio when
    /// only system audio is recorded.
    public let rms: Float
    /// System audio level while it is recorded together with the microphone.
    public let systemRMS: Float?
    /// Recorded time so far (pauses excluded).
    public let recordedTime: TimeInterval
    /// Whether any non-silent system audio arrived so far.
    public let hasReceivedSystemAudio: Bool

    public init(rms: Float, systemRMS: Float? = nil, recordedTime: TimeInterval, hasReceivedSystemAudio: Bool) {
        self.rms = rms
        self.systemRMS = systemRMS
        self.recordedTime = recordedTime
        self.hasReceivedSystemAudio = hasReceivedSystemAudio
    }
}

/// The outcome of a finished recording.
public struct RecordingResult: Sendable {
    /// Recorded seconds, pauses excluded.
    public let duration: TimeInterval
    /// Levels of microphone and system audio; only for microphone + system audio recordings.
    public let sourceActivity: SourceActivity?

    public init(duration: TimeInterval, sourceActivity: SourceActivity? = nil) {
        self.duration = duration
        self.sourceActivity = sourceActivity
    }
}

/// Why a capture source could not be prepared.
public enum CaptureError: Error, Sendable {
    /// The device delivers a format the pipeline cannot convert (not Float32 PCM).
    case unsupportedFormat
}
