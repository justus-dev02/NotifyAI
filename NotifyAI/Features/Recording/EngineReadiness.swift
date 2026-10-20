//
//  EngineReadiness.swift
//  NotifyAI
//

import NotifyAICore
import NotifyAIServices
import SwiftUI

extension TranscriptionSettings {
    /// Whether the selected engine can transcribe right now: its model is downloaded.
    func isReady(whisperModels: WhisperModelManager, neuralModels: NeuralModelManager) -> Bool {
        switch engine {
        case .appleSpeech: true
        case .whisper: whisperModels.isInstalled(whisperModel)
        case .parakeet: neuralModels.isInstalled(.parakeet)
        }
    }
}

extension TranscriptionEngineKind {
    /// Whisper and Parakeet transcribe phrase by phrase; Apple Speech word by word.
    var transcribesInPhrases: Bool { self != .appleSpeech }
}

/// Shows whether the model of the selected engine is available and offers the download.
struct EngineModelStatusRow: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        switch settings.transcription.engine {
        case .appleSpeech: EmptyView()
        case .whisper: WhisperModelStatusRow(model: settings.transcription.whisperModel)
        case .parakeet: ParakeetModelStatusRow()
        }
    }
}

/// Whether the Parakeet model is available, with the download.
private struct ParakeetModelStatusRow: View {
    @Environment(NeuralModelManager.self) private var models
    private let model = NeuralSpeechModel.parakeet

    var body: some View {
        switch models.state(for: model) {
        case .installed:
            LabeledContent("Parakeet-Modell") {
                Label(model.name, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .downloading(let progress):
            LabeledContent("\(model.name) wird geladen") {
                ProgressView(value: progress)
                    .frame(width: 120)
            }
        case .preparing:
            LabeledContent("\(model.name) wird vorbereitet") {
                ProgressView()
                    .controlSize(.small)
            }
        case .notInstalled, .failed:
            VStack(alignment: .leading, spacing: 8) {
                Label("Das Modell „\(model.name)“ ist noch nicht geladen.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("Jetzt laden (\(model.approximateSize))") {
                    models.download(model)
                }
                Text("Einmaliger Download. Danach läuft Parakeet ohne Internet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
