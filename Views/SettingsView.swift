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
    @State private var showingModelSheet = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Spracherkennung & ASR") {
                    Picker("Transkriptions-Engine", selection: $viewModel.transcriptionBackend) {
                        ForEach(TranscriptionService.Backend.allCases) { backend in
                            Text(backend.displayName).tag(backend)
                        }
                    }

                    Picker("Sprache", selection: $viewModel.locale) {
                        ForEach(viewModel.supportedLocaleIdentifiers, id: \.self) { code in
                            Text(localeDescription(for: code)).tag(code)
                        }
                    }

                    if viewModel.transcriptionBackend == .appleSpeech {
                        HStack {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Apple On-Device Speech")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text("Läuft direkt über iOS ohne Cloud-Server.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Toggle("Sprecher-Unterscheidung (Diarisierung)", isOn: $viewModel.diarizationEnabled)
                }

                Section("Lokale KI-Modelle (LLM)") {
                    Button {
                        showingModelSheet = true
                    } label: {
                        HStack {
                            Label("Modell-Katalog & Download", systemImage: "arrow.down.circle.fill")
                                .foregroundStyle(Color.indigo)
                                .fontWeight(.semibold)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("Streaming-Generierung", isOn: $viewModel.streamingEnabled)
                }

                Section("Vorlagen & Templates") {
                    NavigationLink("Transkript-Vorlagen verwalten") {
                        TemplateLibraryView()
                    }
                }

                Section("Datenschutz & Security") {
                    HStack {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(.green)
                        Text("100% On-Device & Offline")
                            .fontWeight(.medium)
                        Spacer()
                    }
                    Toggle("Namen & sensible Daten automatisch schwärzen", isOn: $viewModel.redactionEnabled)
                }
            }
            .navigationTitle("Einstellungen")
            .sheet(isPresented: $showingModelSheet) {
                ModelDownloadSheet()
            }
        }
    }

    private func localeDescription(for code: String) -> String {
        AppleSpeechBackend.localeDescription(for: code)
    }
}

#Preview {
    SettingsView()
        .environmentObject(SettingsViewModel())
}
