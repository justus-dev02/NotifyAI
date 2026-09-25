//
//  OnboardingViewModel.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//  Updated for Onboarding Setup & Permission Verification.
//

import Foundation
import AVFoundation
import Speech

@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case privacy = 0
        case permissions = 1
        case engine = 2

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .privacy: return "Datenschutz"
            case .permissions: return "Berechtigungen"
            case .engine: return "KI-Engine"
            }
        }
    }

    @Published var currentStep: Step = .privacy
    @Published var selectedLocale = "de-DE"
    @Published var micPermissionGranted = false
    @Published var speechPermissionGranted = false
    @Published var selectedBackend: TranscriptionService.Backend = .whisperKit

    init() {
        checkCurrentPermissions()
    }

    func checkCurrentPermissions() {
        let micStatus = AVAudioSession.sharedInstance().recordPermission
        micPermissionGranted = (micStatus == .granted)

        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        speechPermissionGranted = (speechStatus == .authorized)
    }

    func requestMicrophonePermission() async {
        let granted = await ServiceLocator.shared.audioSession.requestPermission()
        micPermissionGranted = granted
    }

    func requestSpeechPermission() async {
        try? await AppleSpeechBackend.shared.requestAuthorization()
        speechPermissionGranted = (SFSpeechRecognizer.authorizationStatus() == .authorized)
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
