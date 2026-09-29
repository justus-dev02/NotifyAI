//
//  RecordingActivityAttributes.swift
//  NotifyAI
//
//  Shared between the app and the widget extension.
//

#if os(iOS)
import ActivityKit
import AppIntents
import Foundation

/// The Live Activity of a running recording (Lock Screen and Dynamic Island).
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isPaused: Bool
        /// Recording start shifted by all pauses, so `Text(timerInterval:)` shows the
        /// recorded time without the app having to update the activity every second.
        var timerStart: Date
        /// Recorded time at the last update; shown while paused.
        var elapsed: TimeInterval
    }

    var title: String
}

/// Actions the Live Activity buttons trigger.
enum RecordingIntentAction: Sendable {
    case togglePause
    case stop
}

/// Connects the Live Activity intents to the recording controller.
///
/// A `LiveActivityIntent` runs in the app's process, so the app sets `handler` at launch.
/// In the widget extension it stays `nil` and is never called.
@MainActor
enum RecordingIntentHandler {
    static var handler: (@MainActor (RecordingIntentAction) async -> Void)?
}

struct ToggleRecordingPauseIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Aufnahme pausieren oder fortsetzen"

    @MainActor
    func perform() async throws -> some IntentResult {
        await RecordingIntentHandler.handler?(.togglePause)
        return .result()
    }
}

struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Aufnahme beenden"

    @MainActor
    func perform() async throws -> some IntentResult {
        await RecordingIntentHandler.handler?(.stop)
        return .result()
    }
}
#endif
