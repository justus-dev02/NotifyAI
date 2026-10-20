//
//  TranscriptEditor.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore
import NotifyAIPersistence
import Observation

/// The user's corrections of a transcript: changed text, removed passages, removed fillers.
///
/// Corrected segments keep their word timings where the words are the same (`WordRetiming`),
/// so playback, highlights and summary sources still point to the right moment. Every change
/// marks the transcript as edited: transcribing again asks first, and speaker detection no
/// longer overwrites it. The summary is not changed; the detail screen offers to summarize
/// again.
@MainActor
@Observable
public final class TranscriptEditor {
    @ObservationIgnored private let writer: TranscriptWriter

    init(store: NoteStore) {
        writer = TranscriptWriter(store: store)
    }

    /// Replaces the text of segments. An empty text removes the segment.
    /// - Returns: Whether anything changed.
    @discardableResult
    public func apply(_ texts: [TranscriptSegment.ID: String], to note: Note) async throws -> Bool {
        var changed = false
        let segments = note.decodedTranscript().compactMap { segment -> TranscriptSegment? in
            guard let text = texts[segment.id] else { return segment }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != segment.text else { return segment }
            changed = true
            guard !trimmed.isEmpty else { return nil }
            var corrected = segment
            corrected.text = trimmed
            corrected.words = WordRetiming.retime(segment.words, to: trimmed, from: segment.start, to: segment.end)
            return corrected
        }
        guard changed else { return false }
        try await writer.save(segments, speakers: note.speakers, to: note, edited: true)
        return true
    }

    /// Removes one passage from the transcript.
    public func delete(_ segmentID: TranscriptSegment.ID, from note: Note) async throws {
        let segments = note.decodedTranscript().filter { $0.id != segmentID }
        try await writer.save(segments, speakers: note.speakers, to: note, edited: true)
    }

    /// Removes filler words in the note's language.
    /// - Returns: Whether anything changed.
    @discardableResult
    public func removeFillerWords(in note: Note) async throws -> Bool {
        let segments = note.decodedTranscript()
        let cleaned = FillerWords(languageCode: note.language.languageCode).remove(from: segments)
        guard cleaned != segments else { return false }
        try await writer.save(cleaned, speakers: note.speakers, to: note, edited: true)
        return true
    }
}

/// Word timings for corrected text.
///
/// The old and the new words are aligned by their longest common subsequence (compared
/// without case and punctuation): unchanged words keep their timing exactly, so fixing a
/// spelling or a comma moves nothing. New or changed words share the time of the words they
/// replace, evenly.
enum WordRetiming {
    static func retime(_ words: [TranscriptWord], to text: String, from start: TimeInterval, to end: TimeInterval) -> [TranscriptWord] {
        guard !words.isEmpty else { return [] }
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let pairs = alignment(words.map { key($0.text) }, tokens.map(key))

        var result: [TranscriptWord] = []
        var newIndex = 0
        var oldIndex = 0
        for (old, new) in pairs + [(words.count, tokens.count)] {
            // The run of new words before this anchor replaces the old words before it.
            if new > newIndex {
                let spanStart = oldIndex < old ? words[oldIndex].start : (oldIndex > 0 ? words[oldIndex - 1].end : start)
                let spanEnd = oldIndex < old ? words[old - 1].end : (old < words.count ? words[old].start : end)
                let count = new - newIndex
                let step = max(0, spanEnd - spanStart) / Double(count)
                for offset in 0..<count {
                    let wordStart = spanStart + step * Double(offset)
                    result.append(TranscriptWord(text: spelled(tokens[newIndex + offset], first: result.isEmpty), start: wordStart, end: wordStart + step))
                }
            }
            if old < words.count, new < tokens.count {
                result.append(TranscriptWord(text: spelled(tokens[new], first: result.isEmpty), start: words[old].start, end: words[old].end))
            }
            oldIndex = old + 1
            newIndex = new + 1
        }
        return result
    }

    /// Words carry their leading space, except the first of a segment.
    private static func spelled(_ token: String, first: Bool) -> String {
        first ? token : " " + token
    }

    private static func key(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Index pairs (old, new) of the longest common subsequence, in order.
    static func alignment(_ old: [String], _ new: [String]) -> [(Int, Int)] {
        let rows = old.count
        let columns = new.count
        var lengths = [[Int]](repeating: [Int](repeating: 0, count: columns + 1), count: rows + 1)
        for row in stride(from: rows - 1, through: 0, by: -1) {
            for column in stride(from: columns - 1, through: 0, by: -1) {
                lengths[row][column] = old[row] == new[column] && !old[row].isEmpty
                    ? lengths[row + 1][column + 1] + 1
                    : max(lengths[row + 1][column], lengths[row][column + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var row = 0
        var column = 0
        while row < rows, column < columns {
            if old[row] == new[column], !old[row].isEmpty {
                pairs.append((row, column))
                row += 1
                column += 1
            } else if lengths[row + 1][column] >= lengths[row][column + 1] {
                row += 1
            } else {
                column += 1
            }
        }
        return pairs
    }
}
