//
//  MenuBarPanel.swift
//  NotifyAI
//

#if os(macOS)
import AppKit
import DesignSystem
import NotifyAICore
import SwiftData
import SwiftUI

/// The icon in the menu bar. Shows the elapsed time while recording.
///
/// Reads only `elapsedSeconds`, which changes once per second: the menu bar item is
/// re-rendered once per second, not with every level update.
struct MenuBarLabel: View {
    let recording: RecordingController

    var body: some View {
        if recording.isActive {
            HStack(spacing: 4) {
                Image(systemName: recording.phase == .paused ? "pause.circle.fill" : "record.circle.fill")
                Text(TimeFormatting.timestamp(TimeInterval(recording.meter.elapsedSeconds)))
                    .monospacedDigit()
            }
        } else {
            Image(systemName: "waveform")
        }
    }
}

/// The popover window that opens from the menu bar icon.
///
/// Recordings can be started, paused, marked and stopped entirely from here, without
/// opening the main window. Note contents are hidden while the app is locked.
struct MenuBarPanel: View {
    @Environment(RecordingController.self) private var recording
    @Environment(AppNavigation.self) private var navigation
    @Environment(AppLock.self) private var appLock
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.appEnvironment) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            header

            Divider()

            if recording.isActive {
                activeRecording
            } else {
                QuickStartForm()
            }

            if !appLock.isLocked, !recording.isActive {
                Divider()
                RecentNotesSection { noteID in
                    navigation.selectedNoteID = noteID
                    showMainWindow()
                }
            }

            Divider()
            footer
        }
        .padding(Theme.Spacing.medium)
        .frame(width: 340)
        .task {
            // The main window may never have been opened (e.g. after a login launch).
            await app?.start()
        }
    }

    private var header: some View {
        HStack {
            Label("NotifyAI", systemImage: "waveform")
                .font(.headline)
            Spacer()
            if recording.isActive {
                RecordingStatusPill()
            }
        }
    }

    private var activeRecording: some View {
        VStack(spacing: Theme.Spacing.medium) {
            HStack(alignment: .center) {
                RecordingElapsedTime()
                    .font(.system(size: 30, weight: .light, design: .rounded))
                Spacer()
                RecordingLevelMeter(source: .main, barCount: 20)
                    .frame(width: 120, height: 28)
            }

            if let message = recording.interruptionMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            SystemAudioStatus(isCompact: true)

            LiveTranscriptPanel(recentSegmentLimit: 12)
                .frame(height: 140)

            if recording.phase == .finishing {
                ProgressView("Transkript wird abgeschlossen …")
                    .controlSize(.small)
            } else {
                RecordingControls(isCompact: true) {
                    Task {
                        if let noteID = await recording.stop() {
                            navigation.selectedNoteID = noteID
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.small)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("NotifyAI öffnen") {
                showMainWindow()
            }
            Spacer()
            Button("Einstellungen", systemImage: "gearshape") {
                openSettings()
                NSApplication.shared.activate()
            }
            .labelStyle(.iconOnly)
            .help("Einstellungen")
            Button("Beenden", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
            .labelStyle(.iconOnly)
            .help("NotifyAI beenden")
            .disabled(recording.isActive)
        }
        .buttonStyle(.borderless)
    }

    private func showMainWindow() {
        openWindow(id: SceneID.main)
        NSApplication.shared.activate()
    }
}

/// Minimal setup for starting a recording from the menu bar.
private struct QuickStartForm: View {
    @Environment(RecordingController.self) private var recording
    @Environment(AppSettings.self) private var settings
    @Environment(WhisperModelManager.self) private var whisperModels
    @Environment(AudioEnvironmentMonitor.self) private var audioEnvironment

    var body: some View {
        @Bindable var recording = recording

        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            TextField("Titel (optional)", text: $recording.draft.title)
                .textFieldStyle(.roundedBorder)

            Picker("Art", selection: $recording.draft.focus) {
                ForEach(RecordingFocus.allCases) { focus in
                    Text(focus.title).tag(focus)
                }
            }

            AudioSourceRows()

            if settings.recording.audioSource == .microphoneAndSystemAudio, audioEnvironment.isLoudspeaker {
                Label("Tipp: Mit Kopfhörern aufnehmen.", systemImage: "headphones")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Toggle("Alle Anwesenden sind einverstanden", isOn: $recording.draft.consentConfirmed)
                .toggleStyle(.checkbox)

            if settings.transcription.engine == .whisper, !whisperModels.isInstalled(settings.transcription.whisperModel) {
                Label("Whisper-Modell fehlt – bitte in den Einstellungen laden.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let error = recording.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button {
                Task { await recording.start() }
            } label: {
                Label("Aufnahme starten", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.recording)
            .controlSize(.large)
            .disabled(!canStart)
            .keyboardShortcut(.defaultAction)

            Text("\(settings.transcription.engine.displayName) · \(settings.transcription.language.displayName) · \(sourceSummary)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .observesAudioEnvironment(.output)
    }

    private var canStart: Bool {
        recording.canStart && (settings.transcription.engine != .whisper || whisperModels.isInstalled(settings.transcription.whisperModel))
    }

    private var sourceSummary: String {
        switch settings.recording.audioSource {
        case .microphone: RecordingAudioSource.microphone.title
        case .microphoneAndSystemAudio: String(localized: "Mikrofon + \(settings.recording.systemAudioTarget.displayName)")
        case .systemAudio: settings.recording.systemAudioTarget.displayName
        }
    }
}

/// The three most recent notes with their processing state.
private struct RecentNotesSection: View {
    let onOpen: (UUID) -> Void
    @Query(Self.descriptor) private var notes: [Note]
    @Environment(ProcessingCoordinator.self) private var processing

    private static var descriptor: FetchDescriptor<Note> {
        var descriptor = FetchDescriptor<Note>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 3
        return descriptor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Zuletzt")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if notes.isEmpty {
                Text("Noch keine Notizen")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(notes) { note in
                Button {
                    onOpen(note.id)
                } label: {
                    HStack(spacing: Theme.Spacing.small) {
                        NoteKindIcon(kind: note.kind, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(note.title)
                                .lineLimit(1)
                            if note.status == .ready {
                                Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                let activity = processing.activities[note.id]
                                NoteStatusLabel(status: activity?.stage ?? note.status, progress: activity?.progress)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Menu bar commands of the main window.
struct AppCommands: Commands {
    let launch: AppLaunch
    let updater: AppUpdater
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Nach Updates suchen …") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        }
        CommandGroup(after: .newItem) {
            Button("Neue Aufnahme …") {
                openWindow(id: SceneID.main)
                launch.environment?.navigation.isRecorderPresented = true
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(launch.environment?.recording.isActive ?? true)
        }
    }
}
#endif
