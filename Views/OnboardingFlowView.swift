import SwiftUI

struct OnboardingFlowView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#C8D7FF") ?? .blue.opacity(0.2), Color(hex: "#F1E6FF") ?? .purple.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            VStack(spacing: 24) {
                welcomeSection
                TabView(selection: $viewModel.currentStep) {
                    privacyCard.tag(OnboardingViewModel.Step.privacy)
                    speechCard.tag(OnboardingViewModel.Step.speech)
                    modelCard.tag(OnboardingViewModel.Step.model)
                    integrationCard.tag(OnboardingViewModel.Step.integrations)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxHeight: 420)
                progressAndButtonsSection
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

// MARK: - Subviews (als Computed Properties)
private extension OnboardingFlowView {
    var welcomeSection: some View {
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
    }

    var progressAndButtonsSection: some View {
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

#Preview {
    OnboardingFlowView(viewModel: OnboardingViewModel())
}
