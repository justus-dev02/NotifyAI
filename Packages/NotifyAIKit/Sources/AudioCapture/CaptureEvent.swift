//
//  CaptureEvent.swift
//  AudioCapture
//

import AVFoundation

/// Where the recorded audio is written. `AVAudioFile` in the app, a test double in tests.
public protocol RecordingSink: AnyObject, Sendable {
    func write(from buffer: AVAudioPCMBuffer) throws
    func close()
}

extension AVAudioFile: RecordingSink {}

/// Something the running capture reports to the recording controller.
public enum CaptureEvent: Sendable, Equatable {
    /// Writing the audio file failed (e.g. the disk is full). No more audio is recorded.
    case writeFailed(String)
    /// The volume holding the recording is almost full; the recording should stop.
    case lowDiskSpace(availableBytes: Int64)
    /// An audio device stopped delivering and could not be restarted (e.g. the microphone
    /// was disconnected and no other one is available). Nothing is recorded until the
    /// recording is resumed successfully.
    case inputFailed(String)
}
