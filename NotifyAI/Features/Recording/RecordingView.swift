//
//  RecordingView.swift
//  NotifyAI
//

import DesignSystem
import NotifyAICore
import NotifyAIServices
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
                    Button(
                        recording.isActive ? String(localized: "Minimieren") : String(localized: "Abbrechen"),
                        systemImage: recording.isActive ? "chevron.down" : "xmark"
                    ) {
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
        .onChange(of: recording.automaticallyStoppedNoteID, initial: true) { _, noteID in
            // The recording stopped on its own (full disk): show its note and the reason.
            guard let noteID else { return }
            recording.acknowledgeAutomaticStop()
            navigation.selectedNoteID = noteID
            dismiss()
        }
        #if os(iOS)
        .userNoticeAlert()
        #endif
    }
}

// MARK: - Setup

private struct RecordingSetupView: View {
    @Environment(RecordingController.self) private var recording
    @Environment(AppSettings.self) private var settings
    @Environment(WhisperModelManager.self) private var whisperModels
    @Environment(NeuralModelManager.self) private var neuralModels

    var body: some View {
        @Bindable var recording = recording
        @Bindable var transcription = settings.transcription

        Form {
            Section {
                TextField("Titel (optional)", text: $recording.draft.title)
                Picker("Art des Gesprächs", selection: $recording.draft.templateChoice) {
                    TemplateChoiceOptions()
                }
                TextField("Teilnehmende (durch Komma getrennt)", text: $recording.draft.participants)
                TextField("Labels (optional, z. B. Firma oder Projekt)", text: $recording.draft.labels)
                Text("Die Art des Gesprächs oder deine Vorlage bestimmt, worauf die Zusammenfassung achtet. Labels nennen den Zusammenhang, etwa deine Firma oder ein Projekt; Zusammenfassung und „Notizen fragen“ nutzen sie.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            #if os(macOS)
            Section {
                AudioSourceRows()
                SystemAudioHints(source: settings.recording.audioSource)
            } header: {
                SectionHeader("Audioquelle")
            } footer: {
                Text(settings.recording.audioSource.detail)
            }
            #endif

            Section {
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
                EngineModelStatusRow()
            } header: {
                SectionHeader("Transkription")
            }

            Section {
                // The explanation is part of the toggle's label: it belongs to the decision,
                // grows with Dynamic Type and is read together with it by VoiceOver.
                Toggle(isOn: $recording.draft.consentConfirmed) {
                    Text("Alle Beteiligten sind mit der Aufnahme einverstanden.")
                    Text("Gespräche dürfen nur mit Zustimmung aller Beteiligten aufgenommen werden, auch in Online-Meetings. Sag am besten zu Beginn, dass du aufnimmst. Die Aufnahme bleibt auf diesem Gerät.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Neue Aufnahme")
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Theme.Spacing.small) {
                if let blocker = RecordingStartBlocker.current(
                    recording: recording, settings: settings, whisperModels: whisperModels, neuralModels: neuralModels
                ) {
                    Label(blocker.message, systemImage: blocker.symbolName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
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
            }
            .padding(Theme.Spacing.large)
        }
    }

    private var canStart: Bool {
        guard recording.canStart else { return false }
        return settings.transcription.isReady(whisperModels: whisperModels, neuralModels: neuralModels)
    }
}

/// Why a recording cannot start yet, so a disabled start button explains itself.
enum RecordingStartBlocker {
    case consentMissing
    case modelMissing(engine: String)

    @MainActor
    static func current(recording: RecordingController, settings: AppSettings, whisperModels: WhisperModelManager, neuralModels: NeuralModelManager) -> Self? {
        guard recording.phase == .idle else { return nil }
        if !settings.transcription.isReady(whisperModels: whisperModels, neuralModels: neuralModels) {
            return .modelMissing(engine: settings.transcription.engine.displayName)
        }
        if !recording.draft.consentConfirmed {
            return .consentMissing
        }
        return nil
    }

    var message: String {
        switch self {
        case .consentMissing: String(localized: "Bestätige zuerst, dass alle Beteiligten einverstanden sind.")
        case .modelMissing(let engine): String(localized: "Das \(engine)-Modell ist noch nicht geladen.")
        }
    }

    var symbolName: String {
        switch self {
        case .consentMissing: "hand.raised"
        case .modelMissing: "arrow.down.circle"
        }
    }
}
