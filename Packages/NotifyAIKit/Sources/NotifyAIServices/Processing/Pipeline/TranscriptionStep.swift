//
//  TranscriptionStep.swift
//  NotifyAIServices
//

import Foundation
import NotifyAIPersistence

/// Step 1: turns the audio file into a transcript, unless the live transcript already exists.
@MainActor
struct TranscriptionStep {
    let transcription: TranscriptionService
    let settings: TranscriptionSettings

    func needsToRun(for note: Note, options: ProcessingOptions) -> Bool {
        note.kind.hasAudio && (options.forceTranscription || !note.hasTranscript)
    }

    func run(_ note: Note, context: ProcessingContext) async throws {
        guard let audioURL = context.store.audioURL(for: note) else {
            throw ProcessingError.missingAudio
        }
        context.setStage(.transcribing, 0)
        let engineKind = settings.engine
        let options = TranscriptionOptions(language: note.language, whisperModel: settings.whisperModel)
        let segments = try await transcription.engine(for: engineKind).transcribeFile(
            at: audioURL,
            options: options,
            progress: context.progress
        )
        try Task.checkCancellation()
        // A new transcript invalidates the summary made from the old one. Cleared before the
        // transcript is saved, so both are written together: a job interrupted right after
        // the save never resumes with the summary of the previous transcript.
        note.summary = nil
        try await context.saveTranscript(segments, engine: engineKind, to: note)
    }
}
