//
//  SettingsView.swift
//  NotifyAI
//
//  Created by OpenAI Assistant on 05.10.23.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: SettingsViewModel
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            Form {
                Section("ASR & Diarisierung") {
                    Picker("Backend", selection: $viewModel.transcriptionBackend) {
                        ForEach(TranscriptionService.Backend.allCases) { backend in
                            Text(backend.displayName).tag(backend)
                        }
                    }

                    Picker("Sprache", selection: $viewModel.locale) {
                        ForEach(viewModel.supportedLocaleIdentifiers, id: \.self) { code in
                            Text(localeDescription(for: code)).tag(code)
                        }
                    }

                    // On-Device Recognition status
                    if viewModel.transcriptionBackend == .appleSpeech {
                        HStack {
                            Image(systemName: viewModel.isOnDeviceRecognitionAvailable
                                  ? "checkmark.circle.fill"
                                  : "exclamationmark.triangle.fill")
                                .foregroundColor(viewModel.isOnDeviceRecognitionAvailable ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(viewModel.isOnDeviceRecognitionAvailable
                                     ? "On-Device-Erkennung verfügbar"
                                     : "On-Device-Erkennung nicht verfügbar")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text(viewModel.isOnDeviceRecognitionAvailable
                                     ? "Spracherkennung läuft offline auf dem Gerät."
                                     : "Für diese Sprache ist ggf. ein Sprachmodell-Download nötig.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Toggle("File-ASR mit WhisperKit", isOn: $viewModel.fileASREnabled)
                    Toggle("Speaker Re-ID aktiv", isOn: $viewModel.diarizationEnabled)

                    NavigationLink("Spracherkennung konfigurieren") {
                        TranscriptionSettingsView()
                    }
                }

                Section("LLM & Performance") {
                    Picker("LLM-Modell", selection: $viewModel.modelId) {
                        ForEach(availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    Toggle("Streaming-Generierung", isOn: $viewModel.streamingEnabled)
                    Toggle("Performance-Modus", isOn: $viewModel.performanceMode)
                }

                Section("Sync & Workspaces") {
                    Toggle("iCloud Sync aktiv", isOn: $viewModel.syncEnabled)
                    Toggle("Shared Workspaces", isOn: $viewModel.sharedWorkspaceEnabled)
                }

                Section("Integrationen") {
                    ForEach(viewModel.integrations) { integration in
                        HStack {
                            Label(integration.kind.title, systemImage: integration.kind.iconName)
                            Spacer()
                            Toggle("", isOn: binding(for: integration.kind))
                                .labelsHidden()
                        }
                    }
                }

                Section("Templates") {
                    NavigationLink("Vorlagen verwalten") {
                        TemplateLibraryView()
                    }
                }

                Section("Datenschutz") {
                    Toggle("Personenbezogene Daten schwärzen", isOn: $viewModel.redactionEnabled)
                    Toggle("Biometrischer Schutz", isOn: $viewModel.biometricLock)
                    Toggle("E2E Verschlüsselung", isOn: $viewModel.endToEndEncryption)
                }
            }
            .navigationTitle("Einstellungen")
        }
    }

    private let availableModels = [
        "phi-3-mini-instruct-q4",
        "llama-3-8b-instruct-q4",
        "mistral-7b-instruct-q4"
    ]

    private func localeDescription(for code: String) -> String {
        AppleSpeechBackend.localeDescription(for: code)
    }

    private func binding(for kind: Integration.Kind) -> Binding<Bool> {
        Binding(get: {
            viewModel.connectedIntegrations.contains(kind)
        }, set: { newValue in
            viewModel.setIntegration(kind, enabled: newValue)
        })
    }
}

#Preview {
    SettingsView()
        .environmentObject(SettingsViewModel())
}
