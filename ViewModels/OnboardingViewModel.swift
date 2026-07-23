import Foundation

@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case privacy
        case speech
        case model

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .privacy: return "Datenschutz"
            case .speech: return "Sprachpaket"
            case .model: return "LLM-Modell"
            }
        }
    }

    @Published var selectedLocale = "de-DE"
    @Published var testPhrase = "Das ist ein kurzer Testsatz."
    @Published var selectedModelQuality: ModelQuality = .balanced
    @Published var selectedModelSize: ModelSize = .phiMini
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    @Published var currentStep: Step = .privacy

    let availableLocales = ["de-DE", "en-US", "fr-FR", "es-ES"]
    let availableModels: [ModelSize] = [.phiMini, .phiMiniInt8, .llama8bInt4]

    func startDownload() {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        Task { await simulateDownload() }
    }

    private func simulateDownload() async {
        for tick in 0...100 {
            try? await Task.sleep(nanoseconds: 40_000_000)
            downloadProgress = Double(tick) / 100.0
        }
        isDownloading = false
    }

    func advance() {
        guard let next = Step(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = next
    }

    func goBack() {
        guard let previous = Step(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = previous
    }
}

extension OnboardingViewModel {
    enum ModelQuality: String, CaseIterable, Identifiable {
        case fast
        case balanced
        case quality

        var id: String { rawValue }

        var label: String {
            switch self {
            case .fast: return "Schnell"
            case .balanced: return "Schnell/Qualität"
            case .quality: return "Qualität"
            }
        }
    }

    enum ModelSize: String, CaseIterable, Identifiable {
        case phiMini
        case phiMiniInt8
        case llama8bInt4

        var id: String { rawValue }

        var title: String {
            switch self {
            case .phiMini: return "Phi-3-mini int4"
            case .phiMiniInt8: return "Phi-3-mini int8"
            case .llama8bInt4: return "LLaMA 3 8B int4"
            }
        }

        var sizeDescription: String {
            switch self {
            case .phiMini: return "1.8 GB"
            case .phiMiniInt8: return "3.2 GB"
            case .llama8bInt4: return "4.5 GB"
            }
        }
    }
}
