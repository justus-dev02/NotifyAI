//
//  TranscriptionStep.swift
//  NotifyAIProcessing
//

import Foundation
import NotifyAIPersistence
import NotifyAISettings
import NotifyAISupport
import NotifyAITranscription

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
        let options = settings.options(for: note.language)
        let recognized = try await transcription.engine(for: engineKind).transcribeFile(
            at: audioURL,
            options: options,
            progress: context.progress
        )
        // Text the audio does not support (recognizers invent phrases in silence) is removed.
        let segments = try await TranscriptVerifier().verify(recognized, audioAt: audioURL)
        try Task.checkCancellation()
        // A new transcript invalidates the summary, the speakers and the corrections made for
        // the old one. Cleared before the transcript is saved, so all is written together: a
        // job interrupted right after the save never resumes with the previous transcript's.
        note.summary = nil
        note.speakers = []
        note.transcriptEditedAt = nil
        try await context.saveTranscript(segments, engine: engineKind, to: note)
    }
}
