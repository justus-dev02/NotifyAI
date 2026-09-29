//
//  Summarizer.swift
//  NotifyAI
//

import Foundation
import FoundationModels
import OSLog

/// Everything a summarizer needs to know about a note.
struct SummaryRequest: Sendable {
    var text: String
    var language: TranscriptionLanguage
    var focus: RecordingFocus
    var kind: NoteKind
    /// Transcript passages the user marked as important.
    var markedPassages: [String]
    /// When the note was recorded or imported; resolves "bis Freitag" and similar.
    var recordedAt: Date = .now
    /// Names the user entered before recording.
    var participants: [String] = []
}

protocol Summarizer: Sendable {
    func summarize(_ request: SummaryRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> NoteSummary
}

/// Whether Apple's on-device language model can be used right now.
enum LanguageModelAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)

    static func current(for language: TranscriptionLanguage) -> LanguageModelAvailability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            guard model.supportsLocale(language.locale) else {
                return .unavailable(reason: "Apple Intelligence unterstützt \(language.displayName) noch nicht.")
            }
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable(reason: "Dieses Gerät unterstützt Apple Intelligence nicht.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(reason: "Apple Intelligence ist in den Systemeinstellungen deaktiviert.")
        case .unavailable(.modelNotReady):
            return .unavailable(reason: "Das Sprachmodell von Apple Intelligence wird noch geladen. Bitte versuche es später erneut.")
        case .unavailable:
            return .unavailable(reason: "Apple Intelligence ist derzeit nicht verfügbar.")
        }
    }
}

/// Chooses the best available summarizer and falls back to extraction when the
/// language model is unavailable or refuses the content.
struct SummarizationService: Sendable {
    private let languageModel: any Summarizer
    private let fallback: any Summarizer
    private let availability: @Sendable (TranscriptionLanguage) -> LanguageModelAvailability

    init(
        languageModel: any Summarizer = FoundationModelSummarizer(),
        fallback: any Summarizer = ExtractiveSummarizer(),
        availability: @escaping @Sendable (TranscriptionLanguage) -> LanguageModelAvailability = LanguageModelAvailability.current
    ) {
        self.languageModel = languageModel
        self.fallback = fallback
        self.availability = availability
    }

    func summarize(_ request: SummaryRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> NoteSummary {
        switch availability(request.language) {
        case .available:
            do {
                return try await languageModel.summarize(request, progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Logger.summarization.error("Language model summary failed: \(error.localizedDescription, privacy: .public)")
                var summary = try await fallback.summarize(request, progress: progress)
                summary.fallbackReason = "Apple Intelligence konnte diesen Text nicht zusammenfassen."
                return summary
            }
        case .unavailable(let reason):
            var summary = try await fallback.summarize(request, progress: progress)
            summary.fallbackReason = reason
            return summary
        }
    }
}
