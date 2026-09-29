//
//  RecordingLiveActivity.swift
//  NotifyAI
//

import Foundation
import OSLog
#if os(iOS)
import ActivityKit
#endif

/// Shows a running recording on the Lock Screen and in the Dynamic Island, like Voice Memos.
/// macOS has the menu bar item instead, so all methods are no-ops there.
@MainActor
final class RecordingLiveActivity {
    #if os(iOS)
    /// `Activity` is not `Sendable`, so async work looks it up by identifier instead of capturing it.
    private var activityID: String?
    private let logger = Logger.audio

    init() {
        // Activities of a session that ended unexpectedly (crash, force quit) would otherwise stay visible.
        // Collected now so a recording started meanwhile is never ended by accident.
        let staleIDs = Activity<RecordingActivityAttributes>.activities.map(\.id)
        Task.detached {
            for id in staleIDs {
                await Self.activity(id: id)?.end(nil, dismissalPolicy: .immediate)
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
        Task.detached {
            await Self.activity(id: activityID)?.update(content)
        }
    }

    func end() {
        guard let activityID else { return }
        self.activityID = nil
        Task.detached {
            await Self.activity(id: activityID)?.end(nil, dismissalPolicy: .immediate)
        }
    }

    private nonisolated static func activity(id: String) -> Activity<RecordingActivityAttributes>? {
        Activity<RecordingActivityAttributes>.activities.first { $0.id == id }
    }

    private static func state(isPaused: Bool, elapsed: TimeInterval) -> RecordingActivityAttributes.ContentState {
        .init(isPaused: isPaused, timerStart: .now.addingTimeInterval(-elapsed), elapsed: elapsed)
    }
    #else
    func start(title: String) {}
    func update(isPaused: Bool, elapsed: TimeInterval) {}
    func end() {}
    #endif
}
