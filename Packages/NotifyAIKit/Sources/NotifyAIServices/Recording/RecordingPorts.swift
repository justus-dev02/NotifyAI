//
//  RecordingPorts.swift
//  NotifyAIServices
//

import AudioCapture
import Foundation
import NotifyAICore

// The parts of a recording that touch hardware or the operating system. `RecordingController`
// depends only on these protocols: the app passes the real implementations, tests pass
// fakes, so the controller's state machine is tested without microphone or Live Activity.

/// Captures audio into a file and streams it. Implemented by `AudioRecorder`.
@MainActor
public protocol AudioRecording: AnyObject {
    /// Recorded time so far, excluding pauses.
    var recordedTime: TimeInterval { get }
    func start(writingTo url: URL, configuration: CaptureConfiguration, streamsAudio: Bool) async throws -> AudioCaptureStreams
    /// Stops writing; the devices keep running so the level meter stays live.
    func pause()
    /// Resumes writing once every device runs again; throws if one cannot be restarted.
    func resume() async throws
    /// Stops, finalizes the file and finishes the streams.
    @discardableResult
    func stop() async -> RecordingResult
    /// Publishes levels only once per second while no meter is visible.
    func setReducedLevelUpdates(_ reduced: Bool)
    /// Ends the audio stream for live transcription; the file is still written.
    func stopStreamingAudio()
}

/// Shows the running recording outside the app, e.g. as a Live Activity on the Lock Screen.
@MainActor
public protocol RecordingActivityPresenting: AnyObject {
    /// Must be called while the app is in the foreground.
    func start(title: String)
    func update(isPaused: Bool, elapsed: TimeInterval)
    func end()
}

/// Keeps the system from throttling or sleeping during a recording and reports when it
/// goes to sleep anyway.
@MainActor
public protocol SystemActivityControlling: AnyObject {
    /// The system is about to sleep (lid closed, "Ruhezustand"). The audio devices stop.
    var willSleep: EventChannel<Void> { get }
    /// Suspends App Nap and idle sleep until `endRecordingActivity()`.
    func beginRecordingActivity()
    func endRecordingActivity()
}

/// Asks for access to the microphone.
public protocol MicrophoneAccess: Sendable {
    /// Asks if needed. Returns whether recording is allowed.
    func requestAccess() async -> Bool
}

/// The system's microphone permission.
public struct SystemMicrophoneAccess: MicrophoneAccess {
    public init() {}

    public func requestAccess() async -> Bool {
        await MicrophonePermission.request()
    }
}

// MARK: - What the controller reports

/// Why a running recording is paused without the user having paused it.
public enum RecordingPauseReason: Equatable, Sendable {
    /// The system interrupted the audio session, e.g. a phone call.
    case systemInterruption
    /// An audio device stopped and could not be restarted.
    case deviceUnavailable(String)
    /// The Mac went to sleep.
    case systemSleep
}

/// Why a recording stopped on its own. What was recorded until then is kept.
public enum AutomaticStopReason: Equatable, Sendable {
    /// The audio file could not be written any more.
    case writeFailed(String)
    /// The volume is almost full.
    case lowDiskSpace(availableBytes: Int64)
}

/// Something the recording controller tells the rest of the app.
public enum RecordingEvent: Equatable, Sendable {
    /// The recording stopped without the user stopping it; `noteID` is the saved note.
    case stoppedAutomatically(noteID: UUID?, reason: AutomaticStopReason)
}

/// Errors that keep a recording from starting.
public enum RecordingError: LocalizedError, Equatable {
    case microphoneAccessDenied

    public var errorDescription: String? {
        switch self {
        case .microphoneAccessDenied:
            String(localized: "Kein Zugriff auf das Mikrofon. Bitte erlaube den Zugriff in den Systemeinstellungen.", bundle: .module)
        }
    }
}
