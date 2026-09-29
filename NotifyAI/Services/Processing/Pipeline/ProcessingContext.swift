//
//  ProcessingContext.swift
//  NotifyAI
//

import Foundation

/// Which steps a job forces even if their result already exists.
struct ProcessingOptions: Equatable, Sendable {
    /// Discard the transcript (and everything derived from it) and transcribe again.
    var forceTranscription = false
    /// Discard the summary and summarize again, from scratch.
    var forceSummary = false
}

/// What a pipeline step needs from its surroundings: the store and a way to report its
/// stage and progress. Steps never touch the job queue.
@MainActor
struct ProcessingContext {
    let store: NoteStore
    let noteID: UUID
    /// Sets the note's status (persisted) and the visible stage with its initial progress.
    let setStage: (NoteStatus, Double?) -> Void
    /// Progress of the current stage (0…1). Callable from any thread.
    let progress: @Sendable (Double) -> Void

    /// Encodes the transcript off the main actor and stores it on the note.
    func saveTranscript(_ segments: [TranscriptSegment], engine: TranscriptionEngineKind?, to note: Note) async throws {
        let normalized = Transcript.normalized(segments)
        guard !normalized.isEmpty else { throw ProcessingError.noSpeechDetected }
        let (data, text) = try await Task.detached(priority: .userInitiated) {
            (try Transcript.encode(normalized), Transcript.plainText(of: normalized))
        }.value
        try Task.checkCancellation()
        note.setTranscript(encoded: data, plainText: text, engine: engine)
        try store.save()
    }
}

enum ProcessingError: LocalizedError {
    case missingAudio
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .missingAudio: "Die Audiodatei dieser Notiz fehlt."
        case .noSpeechDetected: "In der Aufnahme wurde keine Sprache erkannt."
        }
    }
}
