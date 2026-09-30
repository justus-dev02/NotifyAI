//
//  LiveRecordingView.swift
//  NotifyAI
//

import DesignSystem
import NotifyAICore
import SwiftUI

/// The running recording: time, levels, live transcript and controls.
struct LiveRecordingView: View {
    @Environment(RecordingController.self) private var recording
    let onFinish: (UUID) -> Void
    @State private var isConfirmingDiscard = false

    var body: some View {
        VStack(spacing: Theme.Spacing.large) {
            VStack(spacing: Theme.Spacing.small) {
                RecordingStatusPill()
                RecordingElapsedTime()
                    .font(.system(size: 56, weight: .light, design: .rounded))
                    .animation(.default, value: recording.meter.elapsedSeconds)
            }
            .padding(.top, Theme.Spacing.large)

            RecordingLevelMeter(source: .main)
                .frame(height: 56)
                .padding(.horizontal, Theme.Spacing.large)

            #if os(macOS)
            SystemAudioStatus()
                .padding(.horizontal, Theme.Spacing.large)
            #endif

            if let message = recording.interruptionMessage {
                Label(message, systemImage: "phone.arrow.down.left")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }

            LiveTranscriptPanel()
                .frame(maxHeight: .infinity)
                .padding(.horizontal, Theme.Spacing.large)

            if recording.phase == .finishing {
                ProgressView("Transkript wird abgeschlossen …")
                    .padding(.bottom, Theme.Spacing.xLarge)
            } else {
                RecordingControls(onStop: stop)
                    .padding(.bottom, Theme.Spacing.large)
            }
        }
        .frame(maxWidth: Theme.readableWidth)
        .frame(maxWidth: .infinity)
        .navigationTitle(recording.draft.title.isEmpty ? String(localized: "Aufnahme") : recording.draft.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button("Verwerfen", systemImage: "trash", role: .destructive) {
                    isConfirmingDiscard = true
                }
                .disabled(recording.phase == .finishing)
            }
        }
        .confirmationDialog("Aufnahme verwerfen?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
            Button("Verwerfen", role: .destructive) {
                Task { await recording.discard() }
            }
        } message: {
            Text("Die Aufnahme wird gelöscht und nicht gespeichert.")
        }
        .sensoryFeedback(.impact, trigger: recording.markers.count)
    }

    private func stop() {
        Task {
            if let noteID = await recording.stop() {
                onFinish(noteID)
            }
        }
    }
}

/// Finalized text plus the current hypothesis, scrolled to the newest words.
///
/// Built for recordings of several hours: every finalized segment is its own row in a lazy
/// stack, so only the visible rows are laid out, and a finalized row never changes again.
/// Only the last row (the volatile hypothesis, several updates per second) re-renders. While
/// the panel is not visible it observes nothing at all.
struct LiveTranscriptPanel: View {
    @Environment(RecordingController.self) private var recording
    /// Shows only the most recent segments, for the compact menu bar panel.
    var recentSegmentLimit: Int?
    @State private var isVisible = false

    var body: some View {
        ZStack {
            if isVisible {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .onScreenVisibilityChange { isVisible = $0 }
    }

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    switch recording.transcript.state {
                    case .off:
                        placeholder("Das Transkript wird nach der Aufnahme erstellt.")
                    case .preparing:
                        placeholder("Spracherkennung wird vorbereitet …")
                    case .unavailable(let reason):
                        placeholder("Live-Transkript nicht verfügbar: \(reason) Das Transkript wird nach der Aufnahme erstellt.")
                    case .fellBehind:
                        Label(
                            "Die Spracherkennung kommt auf diesem Gerät nicht hinterher. Das Transkript wird nach der Aufnahme aus der Audiodatei erstellt.",
                            systemImage: "hourglass"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)
                    case .running:
                        if recording.transcript.segments.isEmpty, recording.transcript.volatileText.isEmpty {
                            placeholder(recording.transcript.engineKind == .whisper
                                ? "Whisper schreibt abschnittsweise mit – der erste Text erscheint nach einer Sprechpause."
                                : "Sprich los – der Text erscheint hier.")
                        }
                        ForEach(displayedSegments) { segment in
                            FinalizedLine(text: segment.text)
                        }
                        VolatileLine(proxy: proxy, bottomID: bottomID)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.large)
            }
            .onChange(of: recording.transcript.segments.count, initial: true) {
                withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
        }
    }

    private let bottomID = "bottom"

    private var displayedSegments: ArraySlice<TranscriptSegment> {
        let segments = recording.transcript.segments
        guard let recentSegmentLimit else { return segments[...] }
        return segments.suffix(recentSegmentLimit)
    }

    private func placeholder(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .font(.callout)
    }
}

/// One finalized segment. Equatable, so SwiftUI skips it when its text did not change.
private struct FinalizedLine: View, Equatable {
    let text: String

    var body: some View {
        Text(text)
            .lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The current hypothesis. A separate view, so its frequent changes re-render only this line.
private struct VolatileLine: View {
    @Environment(RecordingController.self) private var recording
    let proxy: ScrollViewProxy
    let bottomID: String

    var body: some View {
        let text = recording.transcript.volatileText
        if !text.isEmpty {
            Text(text)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: text) {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
        }
    }
}
