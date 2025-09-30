//
//  SettingsViewModel.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var locale: String = "de-DE" {
        didSet { AppleSpeechBackend.shared.localeIdentifier = locale }
    }
    @Published var redactionEnabled: Bool = true
    @Published var biometricLock: Bool = false
    @Published var endToEndEncryption: Bool = false
    @Published var modelId: String = "phi-3-mini-instruct-q4" {
        didSet { ServiceLocator.shared.llm.modelId = modelId }
    }
    @Published var transcriptionBackend: TranscriptionService.Backend = ServiceLocator.shared.transcription.backend {
        didSet { ServiceLocator.shared.transcription.backend = transcriptionBackend }
    }
    @Published var fileASREnabled: Bool = false
    @Published var diarizationEnabled: Bool = false
    @Published var streamingEnabled: Bool = true
    @Published var performanceMode: Bool = false
    @Published var syncEnabled: Bool = true
    @Published var sharedWorkspaceEnabled: Bool = false

    @Published private(set) var integrations: [Integration] = Integration.Kind.allCases.map { Integration(kind: $0) }
    @Published private(set) var connectedIntegrations: Set<Integration.Kind> = []

    func setIntegration(_ kind: Integration.Kind, enabled: Bool) {
        if enabled {
            connectedIntegrations.insert(kind)
        } else {
            connectedIntegrations.remove(kind)
        }
        integrations = integrations.map { integration in
            guard integration.kind == kind else { return integration }
            var updated = integration
            updated.isConnected = enabled
            updated.details = enabled ? "Verbunden" : "Nicht verbunden"
            return updated
        }
    }
}
