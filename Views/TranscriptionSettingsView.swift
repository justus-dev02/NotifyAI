//
//  TranscriptionSettingsView.swift
//  NotifyAI
//
//  Created by AI Assistant on 23.10.25.
//  Updated with WhisperKit & Apple Speech Switcher.
//

import SwiftUI

struct TranscriptionSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settingsVM: SettingsViewModel

    var body: some View {
        Form {
            // Engine Selection Section
            Section {
                Picker("Transkriptions-Engine", selection: $settingsVM.transcriptionBackend) {
                    ForEach(TranscriptionService.Backend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 4)
            } header: {
                Text("Erkennungs-Technologie")
            } footer: {
                Text(settingsVM.transcriptionBackend == .whisperKit
                     ? "WhisperKit führt OpenAIs Whisper-Modell direkt auf der Apple Neural Engine aus – ideal für komplexe Fachbegriffe und Hintergrundgeräusche."
                     : "Apple Speech nutzt das systemintegrierte On-Device-Sprachmodell von iOS.")
            }

            // Backend specific configuration
            if settingsVM.transcriptionBackend == .whisperKit {
                Section {
                    Picker("Whisper Modell", selection: $settingsVM.whisperModel) {
                        ForEach(WhisperBackend.WhisperModelVariant.allCases) { variant in
                            Text(variant.displayName).tag(variant)
                        }
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "bolt.badge.clock.fill")
                            .font(.title3)
                            .foregroundColor(.indigo)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("On-Device Whisper KI aktiv")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text("Modelle laufen lokal via CoreML & Apple Neural Engine ohne Cloud-Abhängigkeit.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Whisper Konfiguration")
                } footer: {
                    Text("Das Modell wird beim ersten Start automatisch initialisiert und lokal zwischengespeichert.")
                }
            } else {
                // Apple Speech Section
                Section {
                    Picker("Sprache", selection: $settingsVM.locale) {
                        ForEach(settingsVM.supportedLocaleIdentifiers, id: \.self) { code in
                            Text(localeDescription(for: code)).tag(code)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    HStack(spacing: 12) {
                        Image(systemName: settingsVM.isOnDeviceRecognitionAvailable
                              ? "checkmark.shield.fill"
                              : "shield.slash")
                            .font(.title3)
                            .foregroundColor(settingsVM.isOnDeviceRecognitionAvailable ? .green : .orange)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(settingsVM.isOnDeviceRecognitionAvailable
                                 ? "On-Device-Erkennung aktiv"
                                 : "On-Device-Erkennung nicht verfügbar")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(settingsVM.isOnDeviceRecognitionAvailable
                                 ? "Alle Erkennungen laufen lokal auf deinem Gerät. Keine Audiodaten verlassen das iPhone."
                                 : "Für diese Sprache wird ggf. das Offline-Paket aus den iOS-Einstellungen benötigt.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Apple Speech Konfiguration")
                }

                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Sprachmodell in iOS herunterladen", systemImage: "arrow.down.circle")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        VStack(alignment: .leading, spacing: 8) {
                            stepRow(number: 1, text: "Öffne die iOS-Einstellungen")
                            stepRow(number: 2, text: "Tippe auf \"Allgemein\" > \"Sprache & Region\"")
                            stepRow(number: 3, text: "Wähle \"Spracherkennung\" und lade deine Sprache herunter")
                        }
                        .font(.caption)

                        Button("iOS-Einstellungen öffnen") {
                            settingsVM.openSystemSettingsForSpeech()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("System-Modelle")
                }
            }

            // Privacy Section
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.title2)
                        .foregroundColor(.green)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("100% Privatsphäre")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text("Sowohl Whisper als auch Apple Speech und die Textzusammenfassung laufen vollständig offline auf deinem Gerät.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Datenschutz")
            }
        }
        .navigationTitle("Spracherkennung")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func localeDescription(for code: String) -> String {
        AppleSpeechBackend.localeDescription(for: code)
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .fontWeight(.bold)
                .foregroundStyle(.blue)
                .frame(width: 20, alignment: .leading)
            Text(text)
                .foregroundStyle(.primary)
        }
    }
}

#Preview {
    NavigationStack {
        TranscriptionSettingsView()
            .environmentObject(SettingsViewModel())
    }
}
