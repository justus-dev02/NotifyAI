//
//  ModelDownloadManager.swift
//  NotifyAI
//
//  Created by Justus on 21.08.26.
//  Updated for WhisperKit Neural Speech Models & Storage Management.
//

import Foundation
import Combine

/// Speech Recognition Model specification for WhisperKit Neural Engine execution
struct DownloadableSpeechModel: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let variant: String
    let formattedSize: String
    let ramRequired: String
    let speedRating: String
    let description: String
    let isRecommended: Bool
}

final class ModelDownloadManager: NSObject, ObservableObject {
    static let shared = ModelDownloadManager()

    @Published var availableModels: [DownloadableSpeechModel] = []
    @Published var activeModelId: String {
        didSet {
            UserDefaults.standard.set(activeModelId, forKey: "activeWhisperModelId")
        }
    }
    @Published var downloadingModelId: String?
    @Published var downloadProgress: Double = 0.0
    @Published var errorMessage: String?

    override private init() {
        self.activeModelId = UserDefaults.standard.string(forKey: "activeWhisperModelId") ?? "openai_whisper-base"
        super.init()
        setupModelCatalog()
    }

    private func setupModelCatalog() {
        self.availableModels = [
            DownloadableSpeechModel(
                id: "openai_whisper-tiny",
                name: "Whisper Tiny (CoreML Neural Engine)",
                variant: "tiny",
                formattedSize: "75 MB",
                ramRequired: "~120 MB RAM",
                speedRating: "⚡⚡⚡ Ultraschnell",
                description: "Optimiert für maximale Geschwindigkeit und minimale Akkubelastung auf älteren und neueren iPhones.",
                isRecommended: false
            ),
            DownloadableSpeechModel(
                id: "openai_whisper-base",
                name: "Whisper Base (Empfohlen)",
                variant: "base",
                formattedSize: "145 MB",
                ramRequired: "~220 MB RAM",
                speedRating: "⚡⚡ Hohe Präzision",
                description: "Der ideale Kompromiss aus erstklassiger deutscher Worterkennung und zügiger Transkription.",
                isRecommended: true
            ),
            DownloadableSpeechModel(
                id: "openai_whisper-small",
                name: "Whisper Small (Maximale Genauigkeit)",
                variant: "small",
                formattedSize: "460 MB",
                ramRequired: "~650 MB RAM",
                speedRating: "🎓 Höchste Detailtiefe",
                description: "Exzellent für komplexe Fachbegriffe, medizinische oder juristische Meetings und starke Hintergrundgeräusche.",
                isRecommended: false
            )
        ]
    }

    func selectModel(_ model: DownloadableSpeechModel) {
        activeModelId = model.id
        if let variant = WhisperBackend.WhisperModelVariant(rawValue: model.id) {
            WhisperBackend.shared.selectedModel = variant
        }
    }
}
