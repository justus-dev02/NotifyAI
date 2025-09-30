import SwiftUI

struct OnboardingFlowView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#C8D7FF") ?? .blue.opacity(0.2), Color(hex: "#F1E6FF") ?? .purple.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Text("Willkommen bei NotifyAI")
                        .font(.largeTitle)
                        .bold()
                        .padding(.top, 32)
                    Text("Alles bleibt lokal – dein persönlicher Capture-Hub für Meetings, Dokumente und Web.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 32)
                }

                TabView(selection: $viewModel.currentStep) {
                    privacyCard.tag(OnboardingViewModel.Step.privacy)
                    speechCard.tag(OnboardingViewModel.Step.speech)
                    modelCard.tag(OnboardingViewModel.Step.model)
                    integrationCard.tag(OnboardingViewModel.Step.integrations)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxHeight: 420)

                VStack(spacing: 12) {
                    ProgressView(value: Double(viewModel.currentStep.rawValue), total: Double(OnboardingViewModel.Step.allCases.count - 1))
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                        .padding(.horizontal, 32)

                    HStack(spacing: 16) {
                        if viewModel.currentStep != .privacy {
                            Button("Zurück") { viewModel.goBack() }
                                .buttonStyle(.bordered)
                        }

                        Spacer()

                        Button(action: advanceOrFinish) {
                            Label(viewModel.currentStep == .integrations ? "Loslegen" : "Weiter", systemImage: viewModel.currentStep == .integrations ? "checkmark.circle.fill" : "arrow.right.circle.fill")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func advanceOrFinish() {
        if viewModel.currentStep == .integrations {
            hasCompletedOnboarding = true
        } else {
            viewModel.advance()
        }
    }
}

private extension OnboardingFlowView {
    var privacyCard: some View {
        onboardingCard(icon: "lock.shield.fill", title: "Datenschutz") {
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
        onboardingCard(icon: "waveform", title: "Sprachpaket") {
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
        onboardingCard(icon: "brain.head.profile", title: "LLM-Modell") {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Qualität", selection: $viewModel.selectedModelQuality) {
                    ForEach(OnboardingViewModel.ModelQuality.allCases) { quality in
                        Text(quality.label).tag(quality)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.availableModels) { model in
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
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.accentColor)
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 20).stroke(model == viewModel.selectedModelSize ? Color.accentColor.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if viewModel.isDownloading {
                    ProgressView(value: viewModel.downloadProgress) {
                        Text("Lade Modell…")
                    }
                } else {
                    Button("Modell laden") { viewModel.startDownload() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    var integrationCard: some View {
        onboardingCard(icon: "puzzlepiece.extension.fill", title: "Integrationen") {
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
                            .overlay(RoundedRectangle(cornerRadius: 20).stroke(isSelected ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.08), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    func onboardingCard<Content: View>(icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Color.accentColor.opacity(0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2)
                        .bold()
                    Text("Schritt \(viewModel.currentStep.rawValue + 1) von \(OnboardingViewModel.Step.allCases.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
        .padding(.horizontal, 24)
    }

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

#Preview {
    OnboardingFlowView(viewModel: OnboardingViewModel())
}
