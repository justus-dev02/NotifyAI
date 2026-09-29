//
//  NoteProcessingPipeline.swift
//  NotifyAI
//

import Foundation

/// The steps a note goes through after recording or import:
/// transcription → speakers → summary.
///
/// Every step saves its result before the next one starts, so an interrupted job continues
/// with the first missing step. Each step decides itself whether it has to run.
@MainActor
struct NoteProcessingPipeline {
    let transcription: TranscriptionStep
    let speakers: SpeakerStep
    let summary: SummaryStep

    func run(_ note: Note, options: ProcessingOptions, context: ProcessingContext) async throws {
        if transcription.needsToRun(for: note, options: options) {
            try await transcription.run(note, context: context)
        }

        guard note.kind.hasAudio ? note.hasTranscript : !note.bodyText.isEmpty else {
            throw ProcessingError.noSpeechDetected
        }

        if speakers.needsToRun(for: note, options: options) {
            try await speakers.run(note, context: context)
        }

        if summary.needsToRun(for: note, options: options) {
            try await summary.run(note, options: options, context: context)
        }

        note.status = .ready
        note.statusMessage = nil
        try context.store.save()
        // Chapter digests were only needed until the summary was saved.
        await summary.digestStore.remove(noteID: context.noteID)
    }
}
