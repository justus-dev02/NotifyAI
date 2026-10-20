//
//  CleanupStep.swift
//  NotifyAIProcessing
//

import Foundation
import NotifyAICore
import NotifyAIPersistence
import NotifyAISettings
import NotifyAISupport
import NotifyAITranscription

/// Step 1b: removes filler words from a new transcript, if the user wants that.
///
/// Runs after transcription (and after a live transcript was saved), before speakers and the
/// summary, so both work with the clean text. Never touches a transcript the user edited.
/// Removing fillers twice changes nothing, so an interrupted job can simply run it again.
@MainActor
struct CleanupStep {
    let settings: TranscriptionSettings

    func needsToRun(for note: Note) -> Bool {
        settings.removesFillerWords && note.kind.hasAudio && note.hasTranscript && note.transcriptEditedAt == nil
    }

    func run(_ note: Note, context: ProcessingContext) async throws {
        let segments = note.decodedTranscript()
        let cleaned = FillerWords(languageCode: note.language.languageCode).remove(from: segments)
        guard cleaned != segments, !cleaned.isEmpty else { return }
        try await context.saveTranscript(cleaned, engine: note.transcriptionEngine, to: note)
    }
}
