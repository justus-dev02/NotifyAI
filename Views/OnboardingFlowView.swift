//
//  OnboardingFlowView.swift
//  NotifyAI
//
//  Created by Justus on 23.10.25.
//  Updated with Apple Liquid Glass Design & Working Permissions.
//

import SwiftUI

struct OnboardingFlowView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        ZStack {
            VStack(spacing: 20) {
                welcomeHeader

                TabView(selection: $viewModel.currentStep) {
                    privacyCard.tag(OnboardingViewModel.Step.privacy)
                    permissionsCard.tag(OnboardingViewModel.Step.permissions)
                    engineCard.tag(OnboardingViewModel.Step.engine)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxHeight: 460)

                progressAndButtonsSection
            }
            .padding(.horizontal, 20)
        }
        .liquidGlassBackground()
    }

    private var welcomeHeader: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 44))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.indigo, Color.purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .padding(.top, 24)

            Text("Willkommen bei NotifyAI")
                .font(.title.bold())
                .foregroundStyle(Color.adaptiveLabel)

            Text("Dein privater, lokaler KI-Assistent für Meetings, Notizen & Transkripte.")
                .font(.subheadline)
                .foregroundStyle(Color.adaptiveSecondaryLabel)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
    }

    // MARK: - Step 1: Privacy
    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.title2)
                    .foregroundStyle(Color.green)
                Text("100% On-Device Privatsphäre")
                    .font(.headline)
                    .foregroundStyle(Color.adaptiveLabel)
            }

            VStack(alignment: .leading, spacing: 14) {
                privacyFeatureRow(icon: "wifi.slash", title: "Keine Cloud-Verbindung", text: "Deine Aufnahmen verlassen niemals dein Gerät. Alles wird offline verarbeitet.")
                privacyFeatureRow(icon: "cpu.fill", title: "Apple Neural Engine", text: "Transkription und Zusammenfassung laufen direkt auf dem Apple-Silicon-Chip deines iPhones.")
                privacyFeatureRow(icon: "hand.raised.fill", title: "DSGVO- & Vertraulichkeitskonform", text: "Ideal für vertrauliche Meetings, Kundengespräche und interne Notizen.")
            }
        }
        .liquidGlassCard(cornerRadius: 24, padding: 22)
        .padding(.horizontal, 4)
    }

    // MARK: - Step 2: Permissions
    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "mic.badge.checkmark")
                    .font(.title2)
                    .foregroundStyle(Color.indigo)
                Text("Erforderliche Berechtigungen")
                    .font(.headline)
                    .foregroundStyle(Color.adaptiveLabel)
            }

            Text("Damit NotifyAI Audio aufnehmen und in Text umwandeln kann, benötigt die App Zugriff auf dein Mikrofon und die Spracherkennung.")
                .font(.caption)
                .foregroundStyle(Color.adaptiveSecondaryLabel)

            VStack(spacing: 12) {
                Button {
                    Task { await viewModel.requestMicrophonePermission() }
                } label: {
                    HStack {
                        Image(systemName: viewModel.micPermissionGranted ? "checkmark.circle.fill" : "mic.fill")
                            .foregroundStyle(viewModel.micPermissionGranted ? Color.green : Color.indigo)
                        Text(viewModel.micPermissionGranted ? "Mikrofon-Zugriff erteilt" : "Mikrofon aktivieren")
                            .font(.subheadline.bold())
                            .foregroundStyle(Color.adaptiveLabel)
                        Spacer()
                    }
                    .padding(14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(viewModel.micPermissionGranted ? Color.green.opacity(0.4) : Color.white.opacity(0.2), lineWidth: 1))
                }

                Button {
                    Task { await viewModel.requestSpeechPermission() }
                } label: {
                    HStack {
                        Image(systemName: viewModel.speechPermissionGranted ? "checkmark.circle.fill" : "waveform")
                            .foregroundStyle(viewModel.speechPermissionGranted ? Color.green : Color.purple)
                        Text(viewModel.speechPermissionGranted ? "Spracherkennung erteilt" : "Spracherkennung aktivieren")
                            .font(.subheadline.bold())
                            .foregroundStyle(Color.adaptiveLabel)
                        Spacer()
                    }
                    .padding(14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(viewModel.speechPermissionGranted ? Color.green.opacity(0.4) : Color.white.opacity(0.2), lineWidth: 1))
                }
            }
        }
        .liquidGlassCard(cornerRadius: 24, padding: 22)
        .padding(.horizontal, 4)
    }

    // MARK: - Step 3: Engine
    private var engineCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "bolt.badge.automatic.fill")
                    .font(.title2)
                    .foregroundStyle(Color.indigo)
                Text("Standard-Erkennung wählen")
                    .font(.headline)
                    .foregroundStyle(Color.adaptiveLabel)
            }

            VStack(spacing: 12) {
                engineSelectionRow(
                    backend: .whisperKit,
                    title: "Whisper KI (Empfohlen)",
                    subtitle: "Extrem präzise, ideal für Fachbegriffe & Akzente auf der Neural Engine."
                )

                engineSelectionRow(
                    backend: .appleSpeech,
                    title: "Apple Speech",
                    subtitle: "Natives System-Sprachmodell von iOS, ultraschnell und energieeffizient."
                )
            }
        }
        .liquidGlassCard(cornerRadius: 24, padding: 22)
        .padding(.horizontal, 4)
    }

    private var progressAndButtonsSection: some View {
        VStack(spacing: 14) {
            ProgressView(value: Double(viewModel.currentStep.rawValue), total: Double(OnboardingViewModel.Step.allCases.count - 1))
                .progressViewStyle(.linear)
                .tint(Color.indigo)

            HStack(spacing: 16) {
                if viewModel.currentStep != .privacy {
                    Button("Zurück") {
                        withAnimation { viewModel.goBack() }
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.adaptiveSecondaryLabel)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }

                Spacer()

                Button {
                    withAnimation {
                        if viewModel.currentStep == .engine {
                            appState.completeOnboarding()
                        } else {
                            viewModel.advance()
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(viewModel.currentStep == .engine ? "Loslegen" : "Weiter")
                            .font(.headline.bold())
                        Image(systemName: viewModel.currentStep == .engine ? "checkmark" : "chevron.right")
                            .font(.subheadline.bold())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.indigo, in: Capsule())
                    .shadow(color: Color.indigo.opacity(0.35), radius: 8, y: 3)
                }
            }
            .padding(.bottom, 24)
        }
    }

    private func privacyFeatureRow(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(Color.indigo)
                .frame(width: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.adaptiveLabel)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(Color.adaptiveSecondaryLabel)
            }
        }
    }

    private func engineSelectionRow(backend: TranscriptionService.Backend, title: String, subtitle: String) -> some View {
        let isSelected = viewModel.selectedBackend == backend
        return Button {
            viewModel.selectedBackend = backend
            ServiceLocator.shared.transcription.backend = backend
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.indigo : Color.adaptiveSecondaryLabel)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.adaptiveLabel)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.adaptiveSecondaryLabel)
                }
                Spacer()
            }
            .padding(14)
            .background(isSelected ? Color.indigo.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 16))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isSelected ? Color.indigo : Color.white.opacity(0.2), lineWidth: 1.2)
            )
        }
    }
}

#Preview {
    OnboardingFlowView(viewModel: OnboardingViewModel())
        .environmentObject(AppState())
        .environmentObject(ThemeManager())
}
