//
//  RecordingControllerTypes.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore

extension RecordingController {
    public enum Phase: Equatable, Sendable {
        case idle
        case starting
        case recording
        case paused
        /// Stopped; the remaining audio is being transcribed.
        case finishing
    }

    /// What the user entered before starting.
    public struct Draft: Equatable, Sendable {
        public var title = ""
        public var focus: RecordingFocus = .general
        public var participants = ""
        public var consentConfirmed = false

        public init() {}
    }

    /// The system and hardware a recording uses. The app passes the real implementations.
    public struct Devices {
        let recorder: any AudioRecording
        let microphone: any MicrophoneAccess
        let system: any SystemActivityControlling
        /// `nil` where the platform has no such presentation (macOS shows the menu bar item).
        let activity: (any RecordingActivityPresenting)?

        public init(
            recorder: any AudioRecording,
            microphone: any MicrophoneAccess,
            system: any SystemActivityControlling,
            activity: (any RecordingActivityPresenting)?
        ) {
            self.recorder = recorder
            self.microphone = microphone
            self.system = system
            self.activity = activity
        }
    }
}
