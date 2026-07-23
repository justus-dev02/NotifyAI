import SwiftUI

struct OnboardingFlowView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.indigo.opacity(0.25),
                    Color.purple.opacity(0.2),
                    Color.blue.opacity(0.15)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 24) {
                welcomeSection
                
                TabView(selection: $viewModel.currentStep) {
                    privacyCard.tag(OnboardingViewModel.Step.privacy)
                    speechCard.tag(OnboardingViewModel.Step.speech)
                    modelCard.tag(OnboardingViewModel.Step.model)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxHeight: 440)
                
                progressAndButtonsSection
            }
        }
    }

    private func advanceOrFinish() {
        if viewModel.currentStep == .model {
            appState.completeOnboarding()
        } else {
            viewModel.advance()
        }
    }
}

// MARK: - Subviews
private extension OnboardingFlowView {
    var welcomeSection: some View {
        VStack(spacing: 12) {
            Text("Willkommen bei NotifyAI")
                .font(.largeTitle)
                .bold()
                .padding(.top, 32)
            Text("100% Lokale KI-Notizen & Transkription. Deine Daten bleiben garantiert privat auf deinem Gerät.")
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
                .tint(.purple)
                .padding(.horizontal, 32)
                
            HStack(spacing: 16) {
                if viewModel.currentStep != .privacy {
                    Button("Zurück") { viewModel.goBack() }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button(action: advanceOrFinish) {
                    Label(viewModel.currentStep == .model ? "Loslegen" : "Weiter", systemImage: viewModel.currentStep == .model ? "checkmark.circle.fill" : "arrow.right.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
    }
}

#Preview {
    OnboardingFlowView(viewModel: OnboardingViewModel())
}
