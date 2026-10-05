//
//  TranscriptionSettingsSection.swift
//  NotifyAI
//

import NotifyAICore
import NotifyAIServices
import Speech
import SwiftUI

/// Engine, language and live transcription, plus the engine's assets (speech pack or Whisper models).
struct TranscriptionSettingsSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var transcription = settings.transcription

        Section {
            Picker("Spracherkennung", selection: $transcription.engine) {
                ForEach(TranscriptionEngineKind.allCases) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            Picker("Sprache", selection: $transcription.language) {
                ForEach(TranscriptionLanguage.all) { language in
                    Text(language.displayName).tag(language)
                }
            }
            Toggle("Live-Transkript während der Aufnahme", isOn: $transcription.liveTranscription)
        } header: {
            Text("Transkription")
        } footer: {
            Text(transcription.engine.summary)
        }

        if transcription.engine == .appleSpeech {
            Section("Apple Speech") {
                AppleSpeechAssetRow(language: transcription.language)
            }
        } else {
            Section {
                ForEach(WhisperModel.all) { model in
                    WhisperModelRow(model: model, isSelected: transcription.whisperModel == model) {
                        transcription.whisperModel = model
                    }
                }
            } header: {
                Text("Whisper-Modelle")
            } footer: {
                Text("Modelle werden einmalig von Hugging Face geladen und danach ausschließlich lokal ausgeführt. Deine Aufnahmen werden nie hochgeladen.")
            }
        }
    }
}

/// Whether Apple Speech's language pack is installed, with a download button.
private struct AppleSpeechAssetRow: View {
    let language: TranscriptionLanguage
    @State private var status: AssetInventory.Status?
    @State private var isInstalling = false
    @State private var installError: String?

    var body: some View {
        content
            .task(id: language) {
                status = await AppleSpeechEngine.assetStatus(for: language)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let installError {
            Label(installError, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        switch status {
        case .installed:
            LabeledContent("Sprachpaket") {
                Label("Installiert", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .supported:
            LabeledContent("Sprachpaket") {
                Button(isInstalling ? String(localized: "Wird geladen …") : String(localized: "Jetzt laden"), action: install)
                    .disabled(isInstalling)
            }
        case .downloading:
            LabeledContent("Sprachpaket") {
                ProgressView().controlSize(.small)
            }
        case .unsupported:
            Label("\(language.displayName) wird von Apple Speech auf diesem Gerät nicht unterstützt.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case nil:
            ProgressView().controlSize(.small)
        @unknown default:
            EmptyView()
        }
    }

    private func install() {
        isInstalling = true
        Task {
            defer { isInstalling = false }
            installError = nil
            do {
                if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale) {
                    try await AppleSpeechEngine.installAssetsIfNeeded(for: locale)
                }
            } catch {
                installError = error.localizedDescription
            }
            status = await AppleSpeechEngine.assetStatus(for: language)
        }
    }
}
