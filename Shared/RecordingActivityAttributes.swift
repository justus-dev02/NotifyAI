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

/// Carries out what the Live Activity's buttons ask for.
///
/// A `LiveActivityIntent` runs in the app's process. The app registers its implementation
/// with `AppDependencyManager` at launch and the intents receive it through `@Dependency`;
/// no global state is involved. In the widget extension the intents are never performed.
protocol RecordingIntentPerforming: Sendable {
    @MainActor
    func perform(_ action: RecordingIntentAction) async
}

struct ToggleRecordingPauseIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Aufnahme pausieren oder fortsetzen"

    @Dependency private var performer: any RecordingIntentPerforming

    @MainActor
    func perform() async throws -> some IntentResult {
        await performer.perform(.togglePause)
        return .result()
    }
}

struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Aufnahme beenden"

    @Dependency private var performer: any RecordingIntentPerforming

    @MainActor
    func perform() async throws -> some IntentResult {
        await performer.perform(.stop)
        return .result()
    }
}
#endif
