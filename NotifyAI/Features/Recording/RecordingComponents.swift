//
//  RecordingComponents.swift
//  NotifyAI
//

import SwiftUI

/// Shows whether the selected Whisper model is available and offers the download.
struct WhisperModelStatusRow: View {
    let model: WhisperModel
    @Environment(WhisperModelManager.self) private var whisperModels

    var body: some View {
        switch whisperModels.state(for: model) {
        case .installed:
            LabeledContent("Whisper-Modell") {
                Label(model.name, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .downloading(let progress):
            LabeledContent("\(model.name) wird geladen") {
                ProgressView(value: progress)
                    .frame(width: 120)
            }
        case .preparing:
            LabeledContent("\(model.name) wird vorbereitet") {
                ProgressView()
                    .controlSize(.small)
            }
        case .notInstalled, .failed:
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Label("Das Modell „\(model.name)“ ist noch nicht geladen.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("Jetzt laden (\(model.approximateSize))") {
                    whisperModels.download(model)
                }
                Text("Einmaliger Download. Danach läuft Whisper ohne Internet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// "● Aufnahme" / "Pausiert" indicator.
struct RecordingStatusPill: View {
    @Environment(RecordingController.self) private var recording

    var body: some View {
        let isPaused = recording.phase == .paused
        HStack(spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(isPaused ? Color.secondary : Theme.recording)
                .symbolEffect(.pulse, isActive: !isPaused)
            Text(isPaused ? "Pausiert" : "Aufnahme")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.fill.tertiary, in: Capsule())
    }
}

/// Pause, stop and "important" buttons. Shared by the recording screen and the menu bar.
struct RecordingControls: View {
    @Environment(RecordingController.self) private var recording
    var isCompact = false
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: isCompact ? Theme.Spacing.large : Theme.Spacing.xLarge) {
            Button {
                recording.togglePause()
            } label: {
                Label(recording.phase == .paused ? "Fortsetzen" : "Pause", systemImage: recording.phase == .paused ? "play.fill" : "pause.fill")
                    .frame(width: buttonSize, height: buttonSize)
                    .background(.fill.tertiary, in: Circle())
                    .contentShape(Circle())
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .help("Pause / Fortsetzen (⇧⌘P)")

            Button(action: onStop) {
                Label("Beenden", systemImage: "stop.fill")
                    .font(isCompact ? .title3 : .title)
                    .frame(width: buttonSize * 1.35, height: buttonSize * 1.35)
                    .foregroundStyle(.white)
                    .background(Theme.recording, in: Circle())
            }
            .keyboardShortcut(.return, modifiers: .command)
            .help("Aufnahme beenden (⌘↩)")

            Button {
                recording.addMarker()
            } label: {
                Label("Wichtig", systemImage: recording.lastMarker == nil ? "star" : "star.fill")
                    .foregroundStyle(Theme.marker)
                    .frame(width: buttonSize, height: buttonSize)
                    .background(Theme.marker.opacity(0.15), in: Circle())
                    .contentShape(Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .help("Stelle als wichtig markieren (⇧⌘M)")
        }
        .labelStyle(.iconOnly)
        .font(isCompact ? .body : .title2)
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if let marker = recording.lastMarker {
                Text("Markiert bei \(TimeFormatting.timestamp(marker.time))")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .offset(y: isCompact ? -30 : -44)
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .animation(.snappy, value: recording.lastMarker)
    }

    private var buttonSize: CGFloat { isCompact ? 32 : 56 }
}
