//
//  RecordingControllerTypes.swift
//  NotifyAIRecording
//

import Foundation
import NotifyAICore
import NotifyAISupport

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
        /// A template of the user's own; it replaces the guidance of `focus`.
        public var templateID: UUID?
        public var participants = ""
        /// Labels for the note, separated by commas ("Samsung, Projekt Atlas").
        public var labels = ""
        public var consentConfirmed = false

        public init() {}

        /// An empty draft with the given template.
        init(template: SummaryTemplateChoice) {
            switch template {
            case .focus(let focus):
                self.focus = focus
            case .custom(let id):
                templateID = id
            }
        }
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
