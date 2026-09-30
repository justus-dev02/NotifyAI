//
//  RecordingLiveActivityWidget.swift
//  NotifyAIWidgets
//

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Lock Screen banner and Dynamic Island of a running recording.
struct RecordingLiveActivityWidget: Widget {
    /// Opens the recording screen of the app.
    static let recordingURL = URL(string: "notifyai://recording")

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenView(title: context.attributes.title, state: context.state)
                .padding()
                .activityBackgroundTint(.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(Self.recordingURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusIcon(isPaused: context.state.isPaused)
                        .font(.title2)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedTime(state: context.state)
                        .font(.title2.weight(.semibold))
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RecordingButtons(isPaused: context.state.isPaused)
                        .padding(.top, 4)
                }
            } compactLeading: {
                StatusIcon(isPaused: context.state.isPaused)
            } compactTrailing: {
                ElapsedTime(state: context.state)
                    .frame(maxWidth: 52)
            } minimal: {
                StatusIcon(isPaused: context.state.isPaused)
            }
            .keylineTint(.red)
            .widgetURL(Self.recordingURL)
        }
    }
}

private struct LockScreenView: View {
    let title: String
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                StatusIcon(isPaused: state.isPaused)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(state.isPaused ? String(localized: "Aufnahme pausiert") : String(localized: "Aufnahme läuft"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                ElapsedTime(state: state)
                    .font(.title.weight(.semibold))
            }
            RecordingButtons(isPaused: state.isPaused)
        }
    }
}

private struct StatusIcon: View {
    let isPaused: Bool

    var body: some View {
        Image(systemName: isPaused ? "pause.circle.fill" : "waveform")
            .foregroundStyle(isPaused ? .orange : .red)
            .symbolEffect(.variableColor.iterative, isActive: !isPaused)
    }
}

/// Counts up by itself while recording, so the app does not need to update every second.
private struct ElapsedTime: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        Group {
            if state.isPaused {
                Text(Duration.seconds(state.elapsed), format: .time(pattern: state.elapsed >= 3_600 ? .hourMinuteSecond : .minuteSecond))
            } else {
                Text(timerInterval: state.timerStart...Date.distantFuture, countsDown: false)
            }
        }
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
        .foregroundStyle(state.isPaused ? .orange : .red)
    }
}

private struct RecordingButtons: View {
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button(intent: ToggleRecordingPauseIntent()) {
                Label(isPaused ? String(localized: "Fortsetzen") : String(localized: "Pause"), systemImage: isPaused ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(.gray)

            Button(intent: StopRecordingIntent()) {
                Label("Beenden", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(.red)
        }
        .buttonStyle(.borderedProminent)
        .font(.subheadline.weight(.semibold))
    }
}
