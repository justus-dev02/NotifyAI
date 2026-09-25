//
//  SettingsView.swift
//  NotifyAI
//
//  Created by OpenAI Assistant on 05.10.23.
//  Updated for Apple Liquid Glass Design & Persistent Preferences.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: SettingsViewModel
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager
    @State private var showingModelSheet = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    // Transkriptions-Technologie Section
                    transcriptionSection

                    // Modell & Performance Section
                    modelSection

                    // Vorlagen & Personalisierung Section
                    templatesSection

                    // Datenschutz & Sicherheit Section
                    privacySection
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .liquidGlassBackground()
            .navigationTitle("Einstellungen")
            .sheet(isPresented: $showingModelSheet) {
                ModelDownloadSheet()
            }
        }
    }

    // MARK: - Transkriptions Section

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Spracherkennung (STT)", systemImage: "waveform.badge.mic")
                .font(.headline)
                .foregroundStyle(Color.adaptiveLabel)

            NavigationLink {
                TranscriptionSettingsView()
                    .environmentObject(viewModel)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Transkriptions-Engine")
                            .font(.subheadline.bold())
                            .foregroundStyle(Color.adaptiveLabel)
                        Text(viewModel.transcriptionBackend.displayName)
                            .font(.caption)
                            .foregroundStyle(Color.indigo)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(Color.adaptiveTertiaryLabel)
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                )
            }

            Toggle("Sprecher-Erkennung (Diarisierung)", isOn: $viewModel.diarizationEnabled)
                .font(.subheadline)
                .foregroundStyle(Color.adaptiveLabel)
                .tint(Color.indigo)

            Toggle("Echtzeit Live-Transkription", isOn: $viewModel.streamingEnabled)
                .font(.subheadline)
                .foregroundStyle(Color.adaptiveLabel)
                .tint(Color.indigo)
        }
        .liquidGlassCard(cornerRadius: 22, padding: 18)
    }

    // MARK: - Model Section

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("CoreML & KI-Ausführung", systemImage: "cpu.fill")
                .font(.headline)
                .foregroundStyle(Color.adaptiveLabel)

            Button {
                showingModelSheet = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Whisper Modell-Katalog")
                            .font(.subheadline.bold())
                            .foregroundStyle(Color.adaptiveLabel)
                        Text(viewModel.whisperModel.displayName)
                            .font(.caption)
                            .foregroundStyle(Color.indigo)
                    }

                    Spacer()

                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.title3)
                        .foregroundStyle(Color.indigo)
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                )
            }
        }
        .liquidGlassCard(cornerRadius: 22, padding: 18)
    }

    // MARK: - Templates Section

    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Vorlagen & Struktur", systemImage: "square.grid.2x2")
                .font(.headline)
                .foregroundStyle(Color.adaptiveLabel)

            NavigationLink {
                TemplateLibraryView()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Transkript-Vorlagen verwalten")
                            .font(.subheadline.bold())
                            .foregroundStyle(Color.adaptiveLabel)
                        Text("Vertrieb, 1:1, Daily Scrum, Vorlesung")
                            .font(.caption)
                            .foregroundStyle(Color.adaptiveSecondaryLabel)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(Color.adaptiveTertiaryLabel)
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                )
            }
        }
        .liquidGlassCard(cornerRadius: 22, padding: 18)
    }

    // MARK: - Privacy & Security Section

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                .font(.title3)
                .foregroundStyle(Color.green)
                Text("Datenschutz & On-Device Privatsphäre")
                    .font(.headline)
                    .foregroundStyle(Color.adaptiveLabel)
            }

            Text("Alle Aufnahmen, Transkripte und Textzusammenfassungen werden zu 100% lokal auf deinem iPhone verarbeitet und verlassen niemals dein Gerät.")
                .font(.caption)
                .foregroundStyle(Color.adaptiveSecondaryLabel)
                .lineSpacing(3)

            Toggle("Sensible Daten automatisch schwärzen", isOn: $viewModel.redactionEnabled)
                .font(.subheadline)
                .foregroundStyle(Color.adaptiveLabel)
                .tint(Color.indigo)

            Toggle("App mit Face ID / Touch ID schützen", isOn: $viewModel.biometricLock)
                .font(.subheadline)
                .foregroundStyle(Color.adaptiveLabel)
                .tint(Color.indigo)
        }
        .liquidGlassCard(cornerRadius: 22, padding: 18)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(SettingsViewModel())
            .environmentObject(AppState())
            .environmentObject(ThemeManager())
    }
}
