//
//  SettingsView.swift
//  NotifyAI
//
//  Created by OpenAI Assistant on 05.10.23.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: SettingsViewModel

    private let availableLocales = ["de-DE", "en-US", "en-GB", "fr-FR"]
    private let availableModels = [
        "phi-3-mini-instruct-q4",
        "llama-3-8b-instruct-q4",
        "mistral-7b-instruct-q4"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Transkription") {
                    Picker("Backend", selection: $viewModel.transcriptionBackend) {
                        ForEach(TranscriptionService.Backend.allCases) { backend in
                            Text(backend.displayName).tag(backend)
                        }
                    }

                    Picker("Sprache", selection: $viewModel.locale) {
                        ForEach(availableLocales, id: \.self) { code in
                            Text(localeDescription(for: code)).tag(code)
                        }
                    }
                }

                Section("Datenschutz") {
                    Toggle("Personenbezogene Daten schwärzen", isOn: $viewModel.redactionEnabled)
                }

                Section("LLM Modell") {
                    Picker("Lokal installiert", selection: $viewModel.modelId) {
                        ForEach(availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }
            }
            .navigationTitle("Einstellungen")
        }
    }

    private func localeDescription(for code: String) -> String {
        let locale = Locale(identifier: code)
        if let name = locale.localizedString(forIdentifier: code) {
            return "\(name) (\(code))"
        }
        return code
    }
}

#Preview {
    SettingsView()
        .environmentObject(SettingsViewModel())
}
