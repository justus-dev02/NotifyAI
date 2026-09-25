//
//  Transcript.swift
//  NotifyAI
//

import Foundation

/// A single recognized word with its position on the recording timeline.
struct TranscriptWord: Codable, Hashable, Sendable {
    /// The word exactly as produced by the engine, including leading whitespace
    /// and trailing punctuation, so that concatenating all words of a segment
    /// reproduces the segment text.
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

/// A phrase or sentence of a transcript.
///
/// All times are seconds on the *recording timeline*: paused periods are not part of
/// the timeline, so times line up with the saved audio file and with `Marker.time`.
struct TranscriptSegment: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    /// Speaker label assigned by speaker detection, for example "Sprecher 1".
    var speaker: String?
    /// Word-level timing. Empty when the engine could not provide it.
    var words: [TranscriptWord]

    init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        speaker: String? = nil,
        words: [TranscriptWord] = []
    ) {
        self.id = id
        self.start = start
        self.end = max(start, end)
        self.text = text
        self.speaker = speaker
        self.words = words
    }

    var timeRange: ClosedRange<TimeInterval> { start...end }
}

/// Helpers for working with whole transcripts.
enum Transcript {
    /// Sorts segments chronologically and drops segments without visible text.
    static func normalized(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
    }

    /// Plain text of the transcript. Speaker changes start a new labelled line, which gives the
    /// language model (and the full-text search) enough structure without timestamps.
    static func plainText(of segments: [TranscriptSegment]) -> String {
        var lines: [String] = []
        var currentSpeaker: String?
        var currentLine = ""

        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if segment.speaker != currentSpeaker, !currentLine.isEmpty {
                lines.append(currentLine)
                currentLine = ""
            }
            if currentLine.isEmpty, let speaker = segment.speaker {
                currentLine = "\(speaker): "
            } else if !currentLine.isEmpty {
                currentLine += " "
            }
            currentLine += text
            currentSpeaker = segment.speaker
        }
        if !currentLine.isEmpty {
            lines.append(currentLine)
        }
        return lines.joined(separator: "\n")
    }

    /// Text spoken inside `range`, used to give the summarizer the passages the user marked.
    static func text(in range: ClosedRange<TimeInterval>, of segments: [TranscriptSegment]) -> String {
        var parts: [String] = []
        for segment in segments where segment.timeRange.overlaps(range) {
            if segment.words.isEmpty {
                parts.append(segment.text.trimmingCharacters(in: .whitespaces))
            } else {
                let words = segment.words.filter { ($0.start...max($0.start, $0.end)).overlaps(range) }
                parts.append(words.map(\.text).joined().trimmingCharacters(in: .whitespaces))
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func encode(_ segments: [TranscriptSegment]) throws -> Data {
        try JSONEncoder().encode(segments)
    }

    static func decode(_ data: Data) throws -> [TranscriptSegment] {
        try JSONDecoder().decode([TranscriptSegment].self, from: data)
    }
}
