//
//  SettingsView.swift
//  NotifyAI
//

import Speech
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppLock.self) private var appLock
    @Environment(WhisperModelManager.self) private var whisperModels
    @Environment(RecordingController.self) private var recording
    @Environment(\.appEnvironment) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var speechAssetStatus: AssetInventory.Status?
    @State private var isInstallingSpeechAssets = false
    @State private var recordingsSize: Int64?
    @State private var isConfirmingDeleteAll = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Picker("Spracherkennung", selection: $settings.engine) {
                    ForEach(TranscriptionEngineKind.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                Picker("Sprache", selection: $settings.language) {
                    ForEach(TranscriptionLanguage.all) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Toggle("Live-Transkript während der Aufnahme", isOn: $settings.liveTranscription)
            } header: {
                Text("Transkription")
            } footer: {
                Text(settings.engine.summary)
            }

            if settings.engine == .appleSpeech {
                Section("Apple Speech") {
                    appleSpeechStatus
                }
            } else {
                Section {
                    ForEach(WhisperModel.all) { model in
                        WhisperModelRow(model: model, isSelected: settings.whisperModel == model) {
                            settings.whisperModel = model
                        }
                    }
                } header: {
                    Text("Whisper-Modelle")
                } footer: {
                    Text("Modelle werden einmalig von Hugging Face geladen und danach ausschließlich lokal ausgeführt. Deine Aufnahmen werden nie hochgeladen.")
                }
            }

            #if os(macOS)
            Section {
                AudioSourceRows()
                SystemAudioHints(source: settings.audioSource)
            } header: {
                Text("Aufnahmequelle")
            } footer: {
                Text("\(settings.audioSource.detail) Die Auswahl gilt für neue Aufnahmen und kann vor jeder Aufnahme geändert werden.")
            }
            #endif

            Section {
                languageModelStatus
                #if os(macOS)
                Toggle(isOn: $settings.speakersFromAudioSource) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sprecher nach Audioquelle trennen")
                        Text("Bei „Mikrofon + Systemton“ wird deine Stimme als „Ich“ und der Ton der App als „Andere“ beschriftet. Ist genau eine teilnehmende Person eingetragen, erscheint ihr Name.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                #endif
                Toggle(isOn: $settings.speakerDetection) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sprecher erkennen (experimentell)")
                        Text("Ordnet Abschnitte verschiedenen Stimmen zu. Funktioniert am besten bei deutlich unterschiedlichen Stimmen.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Auswertung")
            }

            Section {
                Toggle("App mit \(AppLock.biometryName) schützen", isOn: $settings.appLockEnabled)
                    .onChange(of: settings.appLockEnabled) { _, enabled in
                        if !enabled { appLock.disable() }
                    }
                Toggle("In Geräte-Backups einschließen", isOn: $settings.includeInBackup)
                    .onChange(of: settings.includeInBackup) {
                        app?.applyBackupPreference()
                    }
            } header: {
                Text("Datenschutz")
            } footer: {
                Text("Alle Daten liegen ausschließlich im geschützten Speicher dieser App. Ohne Backup-Freigabe sind sie auch nicht Teil von iCloud- oder Computer-Backups.")
            }

            Section("Speicher") {
                LabeledContent("Aufnahmen") {
                    if let recordingsSize {
                        Text(TimeFormatting.byteCount(recordingsSize))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                LabeledContent("Whisper-Modelle", value: TimeFormatting.byteCount(whisperModels.totalInstalledBytes))
                Button("Alle Notizen löschen …", role: .destructive) {
                    isConfirmingDeleteAll = true
                }
                .disabled(recording.isActive)
            }

            Section {
                LabeledContent("Version", value: Bundle.main.versionDescription)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Einstellungen")
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Fertig") { dismiss() }
            }
        }
        #endif
        .task(id: settings.language) {
            speechAssetStatus = await AppleSpeechEngine.assetStatus(for: settings.language)
        }
        .task {
            await refreshStorage()
        }
        .confirmationDialog("Alle Notizen löschen?", isPresented: $isConfirmingDeleteAll, titleVisibility: .visible) {
            Button("Alle löschen", role: .destructive) {
                app?.processing.cancelAll()
                try? app?.store.deleteAll()
                app?.navigation.selectedNoteID = nil
                Task { await refreshStorage() }
            }
        } message: {
            Text("Alle Aufnahmen, Transkripte und Zusammenfassungen werden endgültig gelöscht.")
        }
    }

    // MARK: Status rows

    @ViewBuilder
    private var appleSpeechStatus: some View {
        switch speechAssetStatus {
        case .installed:
            LabeledContent("Sprachpaket") {
                Label("Installiert", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .supported:
            LabeledContent("Sprachpaket") {
                Button(isInstallingSpeechAssets ? "Wird geladen …" : "Jetzt laden") {
                    installSpeechAssets()
                }
                .disabled(isInstallingSpeechAssets)
            }
        case .downloading:
            LabeledContent("Sprachpaket") {
                ProgressView().controlSize(.small)
            }
        case .unsupported:
            Label("\(settings.language.displayName) wird von Apple Speech auf diesem Gerät nicht unterstützt.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case nil:
            ProgressView().controlSize(.small)
        @unknown default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var languageModelStatus: some View {
        switch LanguageModelAvailability.current(for: settings.language) {
        case .available:
            LabeledContent("Zusammenfassung") {
                Label("Apple Intelligence", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .unavailable(let reason):
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Zusammenfassung", value: "Einfache Zusammenfassung")
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Actions

    private func installSpeechAssets() {
        isInstallingSpeechAssets = true
        Task {
            defer { isInstallingSpeechAssets = false }
            if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: settings.language.locale) {
                try? await AppleSpeechEngine.installAssetsIfNeeded(for: locale)
            }
            speechAssetStatus = await AppleSpeechEngine.assetStatus(for: settings.language)
        }
    }

    private func refreshStorage() async {
        guard let directory = app?.store.locations.recordingsDirectory else { return }
        recordingsSize = await Task.detached(priority: .utility) {
            StorageLocations.allocatedSize(of: directory)
        }.value
    }
}

/// A Whisper model with its download state and actions.
private struct WhisperModelRow: View {
    let model: WhisperModel
    let isSelected: Bool
    let onSelect: () -> Void
    @Environment(WhisperModelManager.self) private var manager
    @State private var isConfirmingDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
            Button(action: onSelect) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "Ausgewählt" : "Auswählen")

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(model.name).font(.body.weight(.semibold))
                    if model == .recommended {
                        Text("Empfohlen")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.15), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                }
                Text(model.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                stateView
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .confirmationDialog("„\(model.name)“ löschen?", isPresented: $isConfirmingDelete) {
            Button("Löschen", role: .destructive) {
                Task { await manager.delete(model) }
            }
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch manager.state(for: model) {
        case .notInstalled:
            Button("Laden (\(model.approximateSize))") { manager.download(model) }
                .controlSize(.small)
        case .downloading(let progress):
            HStack {
                ProgressView(value: progress)
                Button("Abbrechen") { manager.cancelDownload(of: model) }
                    .controlSize(.small)
            }
        case .preparing:
            HStack(spacing: Theme.Spacing.small) {
                ProgressView().controlSize(.small)
                Text("Wird für dieses Gerät vorbereitet …")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .installed(let bytes):
            HStack {
                Label("Geladen · \(TimeFormatting.byteCount(bytes))", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
                Button("Löschen", role: .destructive) { isConfirmingDelete = true }
                    .controlSize(.small)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(.caption).foregroundStyle(.orange)
                Button("Erneut versuchen") { manager.download(model) }
                    .controlSize(.small)
            }
        }
    }
}

private extension Bundle {
    var versionDescription: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
        return "\(version) (\(build))"
    }
}
