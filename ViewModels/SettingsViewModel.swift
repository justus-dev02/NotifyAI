//
//  SettingsViewModel.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//  Updated for Persistent UserDefaults Storage & LocalAuthentication Biometrics.
//

import Foundation
import SwiftUI
import LocalAuthentication

@MainActor
final class SettingsViewModel: ObservableObject {
    /// All locales supported by Apple Speech, as locale identifiers (e.g. "de-DE")
    var supportedLocaleIdentifiers: [String] {
        AppleSpeechBackend.supportedLocales.map(\.identifier)
    }

    @AppStorage("settings_locale") var locale: String = "de-DE" {
        didSet {
            AppleSpeechBackend.shared.localeIdentifier = locale
            objectWillChange.send()
        }
    }

    @AppStorage("settings_redaction_enabled") var redactionEnabled: Bool = true {
        didSet { objectWillChange.send() }
    }

    @AppStorage("settings_biometric_lock") var biometricLock: Bool = false {
        didSet { objectWillChange.send() }
    }

    @AppStorage("settings_diarization_enabled") var diarizationEnabled: Bool = true {
        didSet { objectWillChange.send() }
    }

    @AppStorage("settings_streaming_enabled") var streamingEnabled: Bool = true {
        didSet { objectWillChange.send() }
    }

    @AppStorage("settings_transcription_backend") var transcriptionBackendRaw: String = TranscriptionService.Backend.whisperKit.rawValue {
        didSet {
            if let backend = TranscriptionService.Backend(rawValue: transcriptionBackendRaw) {
                ServiceLocator.shared.transcription.backend = backend
            }
            objectWillChange.send()
        }
    }

    var transcriptionBackend: TranscriptionService.Backend {
        get { TranscriptionService.Backend(rawValue: transcriptionBackendRaw) ?? .whisperKit }
        set { transcriptionBackendRaw = newValue.rawValue }
    }

    @AppStorage("settings_whisper_model") var whisperModelRaw: String = WhisperBackend.WhisperModelVariant.base.rawValue {
        didSet {
            if let variant = WhisperBackend.WhisperModelVariant(rawValue: whisperModelRaw) {
                WhisperBackend.shared.selectedModel = variant
            }
            objectWillChange.send()
        }
    }

    var whisperModel: WhisperBackend.WhisperModelVariant {
        get { WhisperBackend.WhisperModelVariant(rawValue: whisperModelRaw) ?? .base }
        set { whisperModelRaw = newValue.rawValue }
    }

    @Published var isUnlocked: Bool = true
    @Published var authErrorMessage: String?

    init() {
        // Apply persisted settings to backend singletons on launch
        AppleSpeechBackend.shared.localeIdentifier = UserDefaults.standard.string(forKey: "settings_locale") ?? "de-DE"
        if let backendRaw = UserDefaults.standard.string(forKey: "settings_transcription_backend"),
           let backend = TranscriptionService.Backend(rawValue: backendRaw) {
            ServiceLocator.shared.transcription.backend = backend
        }
        if let modelRaw = UserDefaults.standard.string(forKey: "settings_whisper_model"),
           let variant = WhisperBackend.WhisperModelVariant(rawValue: modelRaw) {
            WhisperBackend.shared.selectedModel = variant
        }

        if UserDefaults.standard.bool(forKey: "settings_biometric_lock") {
            isUnlocked = false
        }
    }

    /// Authenticates with Face ID or Touch ID
    func authenticateUser() {
        guard biometricLock else {
            isUnlocked = true
            return
        }

        let context = LAContext()
        var error: NSError?

        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            let reason = "Entsperre NotifyAI, um auf deine vertraulichen Notizen zuzugreifen."
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { [weak self] success, authError in
                DispatchQueue.main.async {
                    if success {
                        self?.isUnlocked = true
                        self?.authErrorMessage = nil
                    } else {
                        self?.authErrorMessage = authError?.localizedDescription ?? "Authentifizierung fehlgeschlagen."
                    }
                }
            }
        } else {
            // Fallback to passcode or direct unlock if biometrics unavailable
            isUnlocked = true
        }
    }

    /// Whether on-device recognition is available for the current locale
    var isOnDeviceRecognitionAvailable: Bool {
        AppleSpeechBackend.shared.isOnDeviceRecognitionAvailable
    }

    /// Opens the system settings app so the user can download speech recognition models
    func openSystemSettingsForSpeech() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
