//
//  RecordingController+Disruptions.swift
//  NotifyAIRecording
//

import AudioCapture
import Foundation
import NotifyAIAudio
import NotifyAICore
import OSLog

/// What interrupts a recording from outside: failing devices, a full disk, write errors,
/// calls and other audio sessions, and the Mac going to sleep.
extension RecordingController {
    func handle(_ event: CaptureEvent) {
        switch event {
        case .inputFailed(let reason):
            inputDidFail(reason: reason)
        case .writeFailed(let reason):
            scheduleAutomaticStop(because: .writeFailed(reason))
        case .lowDiskSpace(let available):
            scheduleAutomaticStop(because: .lowDiskSpace(availableBytes: available))
        }
    }

    /// A device stopped delivering and could not be restarted. Nothing is recorded any
    /// more, so the recording pauses visibly instead of appearing to run.
    func inputDidFail(reason: String) {
        guard phase == .recording || phase == .paused else { return }
        logger.error("Audio input failed: \(reason, privacy: .public)")
        // The end of an interruption must not try to resume a failed device on its own.
        interruptions.userTookOver()
        pause(because: .deviceUnavailable(reason))
    }

    /// The capture cannot continue: stop and keep what was recorded. The stop runs in its
    /// own task, because stopping cancels the task that delivers the events.
    func scheduleAutomaticStop(because reason: AutomaticStopReason) {
        Task { await stopAutomatically(because: reason) }
    }

    func stopAutomatically(because reason: AutomaticStopReason) async {
        guard phase == .recording || phase == .paused else { return }
        logger.error("Stopping the recording automatically: \(String(describing: reason), privacy: .public)")
        let noteID = await stop()
        automaticallyStoppedNoteID = noteID
        events.send(.stoppedAutomatically(noteID: noteID, reason: reason))
    }

    func handleInterruption(_ interruption: AudioSessionController.Interruption) {
        let action = switch interruption {
        case .began:
            interruptions.interruptionBegan(isRecording: phase == .recording)
        case .ended(let shouldResume):
            interruptions.interruptionEnded(shouldResume: shouldResume, isPaused: phase == .paused)
        }
        switch action {
        case .none:
            break
        case .pause:
            pause(because: .systemInterruption)
        case .resume:
            Task { await resume() }
        }
    }

    func pause(because reason: RecordingPauseReason) {
        if phase == .recording {
            recorder.pause()
            phase = .paused
        }
        pauseReason = reason
        liveActivity?.update(isPaused: true, elapsed: recorder.recordedTime)
    }
}
