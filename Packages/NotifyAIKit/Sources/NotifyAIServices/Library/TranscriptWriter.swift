//
//  TranscriptWriter.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore
import NotifyAIPersistence

/// Stores a changed transcript on a note: encoded off the main actor, together with its plain
/// text (search, summary) and its speakers.
@MainActor
struct TranscriptWriter {
    let store: NoteStore

    /// - Parameter edited: Whether the user changed it; transcribing again then asks first and
    ///   speaker detection no longer overwrites it.
    func save(_ segments: [TranscriptSegment], speakers: [NoteSpeaker], to note: Note, edited: Bool) async throws {
        let normalized = Transcript.normalized(segments)
        let engine = note.transcriptionEngine
        let (data, text) = try await Self.encode(normalized)
        note.setTranscript(encoded: data, plainText: text, engine: engine)
        note.speakers = Self.speakers(speakers, measuredIn: normalized)
        if edited {
            note.transcriptEditedAt = .now
        }
        try store.save()
    }

    /// The speakers that still occur, in order of first appearance, with their speech time.
    static func speakers(_ speakers: [NoteSpeaker], measuredIn segments: [TranscriptSegment]) -> [NoteSpeaker] {
        var durations: [String: TimeInterval] = [:]
        var order: [String] = []
        for segment in segments {
            guard let label = segment.speaker else { continue }
            if durations[label] == nil { order.append(label) }
            durations[label, default: 0] += segment.end - segment.start
        }
        return order.map { label in
            var speaker = speakers.first { $0.label == label } ?? NoteSpeaker(label: label, origin: .named)
            speaker.speechDuration = durations[label] ?? 0
            return speaker
        }
    }

    @concurrent
    private static func encode(_ segments: [TranscriptSegment]) async throws -> (data: Data, text: String) {
        (try Transcript.encode(segments), Transcript.plainText(of: segments))
    }
}
