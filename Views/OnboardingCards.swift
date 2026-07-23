//
//  OnboardingCards.swift
//  NotifyAI
//
//  Created by Justus on 23.10.25.
//

import SwiftUI

extension OnboardingFlowView {
    var privacyCard: some View {
        OnboardingCard(icon: "lock.shield.fill", title: "100% Datenschutz", step: viewModel.currentStep) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keine Datenerfassung")
                            .font(.headline)
                        Text("Deine Notizen & Aufnahmen bleiben zu 100% auf deinem Gerät.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                
                HStack(spacing: 12) {
                    Image(systemName: "cpu.fill")
                        .font(.title2)
                        .foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("On-Device KI")
                            .font(.headline)
                        Text("Spracherkennung und KI-Analysen laufen ohne Cloud-Server.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    var speechCard: some View {
        OnboardingCard(icon: "waveform", title: "Sprachpaket", step: viewModel.currentStep) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Wähle deine primäre Sprache für die Offline-Spracherkennung:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                Picker("Sprache", selection: $viewModel.selectedLocale) {
                    ForEach(viewModel.availableLocales, id: \.self) { locale in
                        Text(localeDescription(locale))
                            .tag(locale)
                    }
                }
                .pickerStyle(.segmented)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Testausgabe")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Sprich einen Satz", text: $viewModel.testPhrase)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    var modelCard: some View {
        OnboardingCard(icon: "brain.head.profile", title: "LLM-Modell", step: viewModel.currentStep) {
            VStack(alignment: .leading, spacing: 16) {
                qualityPicker
                modelSelectionGrid
                downloadSection
            }
        }
    }

    // MARK: - Model Card Subviews
    private var qualityPicker: some View {
        Picker("Qualität", selection: $viewModel.selectedModelQuality) {
            ForEach(OnboardingViewModel.ModelQuality.allCases) { quality in
                Text(quality.label).tag(quality)
            }
        }
        .pickerStyle(.segmented)
    }

    private var modelSelectionGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(viewModel.availableModels) { model in
                modelSelectionButton(for: model)
            }
        }
    }

    private func modelSelectionButton(for model: OnboardingViewModel.ModelSize) -> some View {
        Button {
            viewModel.selectedModelSize = model
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(model.title)
                        .font(.headline)
                    Text(model.sizeDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model == viewModel.selectedModelSize {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(model == viewModel.selectedModelSize ? Color.accentColor.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var downloadSection: some View {
        Group {
            if viewModel.isDownloading {
                ProgressView(value: viewModel.downloadProgress) {
                    Text("Lade Modell…")
                }
            } else {
                Button("Modell laden") {
                    viewModel.startDownload()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Helper Functions
    func localeDescription(_ code: String) -> String {
        let locale = Locale(identifier: code)
        return locale.localizedString(forIdentifier: code) ?? code
    }
}
