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
    @Published var modelId: String = "phi-3-mini-instruct-q4" {
        didSet { ServiceLocator.shared.llm.modelId = modelId }
    }
}
