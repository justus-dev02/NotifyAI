//
//  OnboardingCards.swift
//  NotifyAI
//
//  Created by Justus on 23.10.25.
//

import SwiftUI

extension OnboardingFlowView {
    var privacyCard: some View {
        OnboardingCard(icon: "lock.shield.fill", title: "Datenschutz", step: viewModel.currentStep) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Alle Verarbeitung passiert on-device. Deine Daten verlassen das Gerät nur, wenn du eine Integration aktivierst.")
                    .font(.body)
                Toggle(isOn: $viewModel.analyticsEnabled) {
                    VStack(alignment: .leading) {
                        Text("Anonyme Nutzungsanalyse")
                        Text("Hilf uns bei der Optimierung – optional.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
            .padding(.top, 8)
        }
    }

    var speechCard: some View {
        OnboardingCard(icon: "waveform", title: "Sprachpaket", step: viewModel.currentStep) {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Sprache", selection: $viewModel.selectedLocale) {
                    ForEach(viewModel.availableLocales, id: \.self) { locale in
                        Text(localeDescription(locale))
                            .tag(locale)
                    }
                }
                .pickerStyle(.wheel)
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

    var integrationCard: some View {
        OnboardingCard(icon: "puzzlepiece.extension.fill", title: "Integrationen", step: viewModel.currentStep) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Verbinde Tools für Push & Pull Workflows. Du kannst Integrationen später jederzeit anpassen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: .init(.flexible(), spacing: 16), count: 2), spacing: 16) {
                    ForEach(viewModel.integrationOptions, id: \.self) { kind in
                        let isSelected = viewModel.selectedIntegrations.contains(kind)
                        Button {
                            viewModel.toggleIntegration(kind)
                        } label: {
                            integrationButton(for: kind, isSelected: isSelected)
                        }
                        .buttonStyle(.plain)
                    }
                }
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
                .buttonStyle(.bordered)
            }
        }
    }

    private func integrationButton(for kind: Integration.Kind, isSelected: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: kind.iconName)
                .font(.largeTitle)
            Text(kind.title)
                .font(.headline)
            Text(kindDescription(kind))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(isSelected ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Helper Functions
    func localeDescription(_ code: String) -> String {
        let locale = Locale(identifier: code)
        return locale.localizedString(forIdentifier: code) ?? code
    }

    func kindDescription(_ kind: Integration.Kind) -> String {
        switch kind {
        case .notion: return "Exportiere Zusammenfassungen direkt in deine Notion-Datenbanken."
        case .googleDrive: return "Lege Audios und PDFs strukturiert in Drive ab."
        case .googleDocs: return "Pushe Highlights in vorbereitete Docs."
        case .calendar: return "Ziehe Meetings automatisch aus deinem Kalender."
        case .zoom: return "Importiere fertige Aufnahmen aus Zoom automatisch."
        }
    }
}
