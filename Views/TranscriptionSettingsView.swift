//
//  TranscriptionSettingsView.swift
//  NotifyAI
//
//  Created by AI Assistant on 23.10.25.
//

import SwiftUI

struct TranscriptionSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settingsVM: SettingsViewModel

    var body: some View {
        Form {
            // Status Section
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.title2)
                        .foregroundColor(.accentColor)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Apple Speech Erkennung")
                            .font(.headline)
                        Text("Systemintegrierte Spracherkennung mit On-Device-Unterstützung")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            // Language Selection
            Section {
                Picker("Sprache", selection: $settingsVM.locale) {
                    ForEach(settingsVM.supportedLocaleIdentifiers, id: \.self) { code in
                        Text(localeDescription(for: code)).tag(code)
                    }
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("Sprache")
            } footer: {
                Text("Die Spracherkennung wird für die ausgewählte Sprache optimiert. On-Device-Modelle werden von iOS automatisch verwaltet.")
            }

            // On-Device Recognition Info
            Section {
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
                             ? "Alle Erkennungen laufen lokal auf deinem Gerät. Keine Daten werden an Apple gesendet."
                             : "Für diese Sprache wird ggf. eine Internetverbindung benötigt. Lade das Sprachmodell in den iOS-Einstellungen herunter.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            // Model Download Guidance
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Sprachmodell herunterladen", systemImage: "arrow.down.circle")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text("iOS lädt Sprachmodelle automatisch herunter, wenn sie benötigt werden. So gehst du vor:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        stepRow(number: 1, text: "Öffne die iOS-Einstellungen")
                        stepRow(number: 2, text: "Tippe auf \"Allgemein\" > \"Sprache & Region\"")
                        stepRow(number: 3, text: "Wähle \"Spracherkennung\"")
                        stepRow(number: 4, text: "Lade die gewünschte Sprache herunter")
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
                Text("Modell-Download")
            }

            // Privacy Info
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Datenschutz", systemImage: "hand.raised.fill")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text("Apple Speech mit On-Device-Erkennung verarbeitet alle Audiodaten lokal auf deinem Gerät. Keine Daten werden an Server gesendet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
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
