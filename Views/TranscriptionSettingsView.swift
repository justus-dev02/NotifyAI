//
//  TranscriptionSettingsView.swift
//  NotifyAI
//
//  Created by AI Assistant on 23.10.25.
//  Updated with Apple Liquid Glass Design.
//

import SwiftUI

struct TranscriptionSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settingsVM: SettingsViewModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                // Engine Selection Card
                engineSelectionCard

                // Engine Specific Settings
                if settingsVM.transcriptionBackend == .whisperKit {
                    whisperConfigCard
                } else {
                    appleSpeechConfigCard
                    modelDownloadCard
                }

                // Privacy Card
                privacyCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .liquidGlassBackground()
        .navigationTitle("Spracherkennung")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Engine Selection Card

    private var engineSelectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Erkennungs-Technologie", systemImage: "waveform.and.person.filled")
                .font(.headline)
                .foregroundStyle(Color.adaptiveLabel)

            Picker("Transkriptions-Engine", selection: $settingsVM.transcriptionBackend) {
                ForEach(TranscriptionService.Backend.allCases) { backend in
                    Text(backend == .whisperKit ? "Whisper (CoreML)" : "Apple Speech").tag(backend)
                }
            }
            .pickerStyle(.segmented)

            Text(settingsVM.transcriptionBackend == .whisperKit
                 ? "WhisperKit führt OpenAIs Whisper-Modell direkt auf der Apple Neural Engine aus – ideal für Fachbegriffe und Hintergrundgeräusche."
                 : "Apple Speech nutzt das native On-Device-Sprachmodell von iOS.")
                .font(.caption)
                .foregroundStyle(Color.adaptiveSecondaryLabel)
                .lineSpacing(2)
        }
        .liquidGlassCard(cornerRadius: 22, padding: 18)
    }

    // MARK: - Whisper Config Card

    private var whisperConfigCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Whisper Modell-Konfiguration", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(Color.adaptiveLabel)

            Picker("Modell-Größe", selection: $settingsVM.whisperModel) {
                ForEach(WhisperBackend.WhisperModelVariant.allCases) { variant in
                    Text(variant.displayName).tag(variant)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
            )

            HStack(spacing: 12) {
                Image(systemName: "bolt.badge.clock.fill")
                    .font(.title3)
                    .foregroundColor(.indigo)

                VStack(alignment: .leading, spacing: 2) {
                    Text("On-Device Whisper KI aktiv")
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.adaptiveLabel)
                    Text("Ausführung auf der Apple Neural Engine ohne Cloud-Verbindung.")
                        .font(.caption)
                        .foregroundStyle(Color.adaptiveSecondaryLabel)
                }
            }
        }
        .liquidGlassCard(cornerRadius: 22, padding: 18)
    }

    // MARK: - Apple Speech Config Card

    private var appleSpeechConfigCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Apple Speech Konfiguration", systemImage: "gearshape")
                .font(.headline)
                .foregroundStyle(Color.adaptiveLabel)

            Picker("Sprache", selection: $settingsVM.locale) {
                ForEach(settingsVM.supportedLocaleIdentifiers, id: \.self) { code in
                    Text(localeDescription(for: code)).tag(code)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
            )

            HStack(spacing: 12) {
                Image(systemName: settingsVM.isOnDeviceRecognitionAvailable
                      ? "checkmark.shield.fill"
                      : "shield.slash")
                    .font(.title3)
                    .foregroundColor(settingsVM.isOnDeviceRecognitionAvailable ? .green : .orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(settingsVM.isOnDeviceRecognitionAvailable
                         ? "On-Device-Erkennung aktiv"
                         : "On-Device-Erkennung nicht verfügbar")
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.adaptiveLabel)
                    Text(settingsVM.isOnDeviceRecognitionAvailable
                         ? "Alle Audiodaten werden offline verarbeitet."
                         : "Für Offline-Betrieb Sprachpaket in den iOS-Einstellungen laden.")
                        .font(.caption)
                        .foregroundStyle(Color.adaptiveSecondaryLabel)
                }
            }
        }
        .liquidGlassCard(cornerRadius: 22, padding: 18)
    }

    // MARK: - Model Download Card

    private var modelDownloadCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("System-Sprachmodell laden", systemImage: "arrow.down.circle")
                .font(.headline)
                .foregroundStyle(Color.adaptiveLabel)

            VStack(alignment: .leading, spacing: 6) {
                stepRow(number: 1, text: "Öffne die iOS-Einstellungen")
                stepRow(number: 2, text: "Tippe auf \"Allgemein\" > \"Sprache & Region\"")
                stepRow(number: 3, text: "Wähle \"Spracherkennung\" & lade dein Sprachpaket")
            }
            .font(.caption)

            Button("iOS-Einstellungen öffnen") {
                settingsVM.openSystemSettingsForSpeech()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 4)
        }
        .liquidGlassCard(cornerRadius: 22, padding: 18)
    }

    // MARK: - Privacy Card

    private var privacyCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.title2)
                .foregroundColor(.green)

            VStack(alignment: .leading, spacing: 3) {
                Text("100% Offline & Lokal")
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.adaptiveLabel)
                Text("Sowohl Whisper als auch Apple Speech laufen komplett auf deinem iPhone.")
                    .font(.caption)
                    .foregroundStyle(Color.adaptiveSecondaryLabel)
            }
        }
        .liquidGlassCard(cornerRadius: 22, padding: 16)
    }

    private func localeDescription(for code: String) -> String {
        AppleSpeechBackend.localeDescription(for: code)
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .fontWeight(.bold)
                .foregroundStyle(Color.indigo)
                .frame(width: 18, alignment: .leading)
            Text(text)
                .foregroundStyle(Color.adaptiveSecondaryLabel)
        }
    }
}

#Preview {
    NavigationStack {
        TranscriptionSettingsView()
            .environmentObject(SettingsViewModel())
    }
}
