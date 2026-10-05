//
//  ProcessingContext.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore
import NotifyAIPersistence

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
        let (data, text) = try await Self.encode(normalized)
        try Task.checkCancellation()
        note.setTranscript(encoded: data, plainText: text, engine: engine)
        try store.save()
    }

    /// Encoding a four-hour transcript takes noticeable time; it runs off the main actor.
    @concurrent
    private static func encode(_ segments: [TranscriptSegment]) async throws -> (data: Data, text: String) {
        (try Transcript.encode(segments), Transcript.plainText(of: segments))
    }
}

enum ProcessingError: LocalizedError {
    case missingAudio
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .missingAudio: String(localized: "Die Audiodatei dieser Notiz fehlt.", bundle: .module)
        case .noSpeechDetected: String(localized: "In der Aufnahme wurde keine Sprache erkannt.", bundle: .module)
        }
    }
}
