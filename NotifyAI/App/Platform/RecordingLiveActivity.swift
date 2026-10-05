//
//  RecordingLiveActivity.swift
//  NotifyAI
//

#if os(iOS)
import ActivityKit
import Foundation
import NotifyAICore
import NotifyAIServices
import OSLog

/// Shows a running recording on the Lock Screen and in the Dynamic Island, like Voice Memos.
/// macOS has the menu bar item instead and passes no presenter to the recording controller.
@MainActor
final class RecordingLiveActivity: RecordingActivityPresenting {
    /// `Activity` is not `Sendable`, so async work looks it up by identifier instead of capturing it.
    private var activityID: String?
    private let logger = Logger.audio

    init() {
        // Activities of a session that ended unexpectedly (crash, force quit) would otherwise stay visible.
        // Collected now so a recording started meanwhile is never ended by accident.
        let staleIDs = Activity<RecordingActivityAttributes>.activities.map(\.id)
        Task {
            for id in staleIDs {
                await Self.endActivity(id: id)
            }
        }
    }

    /// Must be called while the app is in the foreground.
    func start(title: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = Self.state(isPaused: false, elapsed: 0)
        do {
            activityID = try Activity.request(
                attributes: RecordingActivityAttributes(title: title),
                content: ActivityContent(state: state, staleDate: nil)
            ).id
        } catch {
            logger.error("Starting the Live Activity failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func update(isPaused: Bool, elapsed: TimeInterval) {
        guard let activityID else { return }
        let content = ActivityContent(state: Self.state(isPaused: isPaused, elapsed: elapsed), staleDate: nil)
        Task {
            await Self.updateActivity(id: activityID, content: content)
        }
    }

    func end() {
        guard let activityID else { return }
        self.activityID = nil
        Task {
            await Self.endActivity(id: activityID)
        }
    }

    // `Activity` is not `Sendable`: it is looked up and used entirely off the main actor.

    @concurrent
    nonisolated private static func updateActivity(id: String, content: ActivityContent<RecordingActivityAttributes.ContentState>) async {
        await activity(id: id)?.update(content)
    }

    @concurrent
    nonisolated private static func endActivity(id: String) async {
        await activity(id: id)?.end(nil, dismissalPolicy: .immediate)
    }

    nonisolated private static func activity(id: String) -> Activity<RecordingActivityAttributes>? {
        Activity<RecordingActivityAttributes>.activities.first { $0.id == id }
    }

    private static func state(isPaused: Bool, elapsed: TimeInterval) -> RecordingActivityAttributes.ContentState {
        .init(isPaused: isPaused, timerStart: .now.addingTimeInterval(-elapsed), elapsed: elapsed)
    }
}

/// Lets the Live Activity's buttons control the recording (`RecordingIntentPerforming`).
@MainActor
final class RecordingIntentPerformer: RecordingIntentPerforming {
    private let recording: RecordingController

    init(recording: RecordingController) {
        self.recording = recording
    }

    func perform(_ action: RecordingIntentAction) async {
        switch action {
        case .togglePause:
            await recording.togglePause()
        case .stop:
            await recording.stop()
        }
    }
}
#endif
