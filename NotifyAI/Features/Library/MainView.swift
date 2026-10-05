//
//  MainView.swift
//  NotifyAI
//

import DesignSystem
import NotifyAIServices
import SwiftUI

/// Library on the left, note on the right. On iPhone the split view collapses into a stack.
struct MainView: View {
    @Environment(AppNavigation.self) private var navigation
    @Environment(RecordingController.self) private var recording

    var body: some View {
        @Bindable var navigation = navigation

        NavigationSplitView {
            LibraryView()
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
                #endif
        } detail: {
            switch navigation.selection {
            case .note(let noteID):
                NoteDetailContainer(noteID: noteID)
                    .id(noteID)
            case .tasks:
                TaskOverviewView()
            case nil:
                ContentUnavailableView(
                    "Keine Notiz ausgewählt",
                    systemImage: "waveform",
                    description: Text("Wähle eine Notiz aus oder starte eine neue Aufnahme.")
                )
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Keeps a running recording reachable after its screen was closed.
            if recording.isActive, !navigation.isRecorderPresented {
                RecordingStatusBar()
                    .padding(.horizontal)
                    .padding(.bottom, Theme.Spacing.small)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: recording.isActive)
        .sheet(isPresented: $navigation.isChatPresented) {
            NoteChatView()
                #if os(macOS)
                .frame(minWidth: 620, idealWidth: 720, minHeight: 560, idealHeight: 720)
                #endif
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $navigation.isRecorderPresented) {
            RecordingView()
        }
        .sheet(isPresented: $navigation.isSettingsPresented) {
            NavigationStack {
                SettingsView()
            }
        }
        #else
        .sheet(isPresented: $navigation.isRecorderPresented) {
            RecordingView()
                .frame(minWidth: 560, idealWidth: 620, minHeight: 620, idealHeight: 700)
        }
        #endif
    }
}

/// Compact bar for a recording whose full-screen view was dismissed.
private struct RecordingStatusBar: View {
    @Environment(RecordingController.self) private var recording
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        Button {
            navigation.isRecorderPresented = true
        } label: {
            HStack(spacing: Theme.Spacing.medium) {
                Image(systemName: recording.phase == .paused ? "pause.circle.fill" : "record.circle")
                    .symbolEffect(.pulse, isActive: recording.phase == .recording)
                    .foregroundStyle(Theme.recording)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 0) {
                    Text(recording.phase == .paused ? String(localized: "Aufnahme pausiert") : String(localized: "Aufnahme läuft"))
                        .font(.subheadline.weight(.semibold))
                    RecordingElapsedTime()
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Öffnen")
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.vertical, Theme.Spacing.medium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .frame(maxWidth: 520)
    }
}
