//
//  RecordingView.swift
//  NotifyAI
//

import SwiftUI

/// Full-screen (iOS) or sheet (macOS) recording flow: setup, then the live session.
struct RecordingView: View {
    @Environment(RecordingController.self) private var recording
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if recording.phase == .idle {
                    RecordingSetupView()
                } else {
                    LiveRecordingView { noteID in
                        navigation.selectedNoteID = noteID
                        dismiss()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Closing does not stop a running recording; it continues in the background.
                    Button(recording.isActive ? "Minimieren" : "Abbrechen", systemImage: recording.isActive ? "chevron.down" : "xmark") {
                        dismiss()
                    }
                }
            }
        }
        .alert("Aufnahme nicht möglich", isPresented: Binding(
            get: { recording.errorMessage != nil },
            set: { if !$0 { recording.dismissError() } }
        )) {
            Button("OK") { recording.dismissError() }
        } message: {
            Text(recording.errorMessage ?? "")
        }
    }
}

// MARK: - Setup

private struct RecordingSetupView: View {
    @Environment(RecordingController.self) private var recording
    @Environment(AppSettings.self) private var settings
    @Environment(WhisperModelManager.self) private var whisperModels

    var body: some View {
        @Bindable var recording = recording
        @Bindable var transcription = settings.transcription

        Form {
            Section {
                TextField("Titel (optional)", text: $recording.draft.title)
                Picker("Art des Gesprächs", selection: $recording.draft.focus) {
                    ForEach(RecordingFocus.allCases) { focus in
                        Label(focus.title, systemImage: focus.symbolName).tag(focus)
                    }
                }
                TextField("Teilnehmende (durch Komma getrennt)", text: $recording.draft.participants)
            } footer: {
                Text("Die Art des Gesprächs bestimmt, worauf die Zusammenfassung achtet.")
            }

            #if os(macOS)
            Section {
                AudioSourceRows()
                SystemAudioHints(source: settings.recording.audioSource)
            } header: {
                Text("Audioquelle")
            } footer: {
                Text(settings.recording.audioSource.detail)
            }
            #endif

            Section("Transkription") {
                Picker("Sprache", selection: $transcription.language) {
                    ForEach(TranscriptionLanguage.all) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Picker("Spracherkennung", selection: $transcription.engine) {
                    ForEach(TranscriptionEngineKind.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                Toggle("Live-Transkript anzeigen", isOn: $transcription.liveTranscription)
                if transcription.engine == .whisper {
                    WhisperModelStatusRow(model: transcription.whisperModel)
                }
            }

            Section {
                Toggle(isOn: $recording.draft.consentConfirmed) {
                    Text("Alle Anwesenden sind mit der Aufnahme einverstanden.")
                }
            } footer: {
                Text("Gespräche dürfen nur mit Zustimmung aller Beteiligten aufgenommen werden. Die Aufnahme bleibt auf diesem Gerät.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Neue Aufnahme")
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await recording.start() }
            } label: {
                Label(recording.phase == .starting ? "Wird gestartet …" : "Aufnahme starten", systemImage: "mic.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.small)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.recording)
            .controlSize(.large)
            .disabled(!canStart)
            .keyboardShortcut(.defaultAction)
            .padding(Theme.Spacing.large)
        }
    }

    private var canStart: Bool {
        guard recording.canStart else { return false }
        return settings.transcription.engine != .whisper || whisperModels.isInstalled(settings.transcription.whisperModel)
    }
}
