//
//  TranscriptEditor.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore
import NotifyAIPersistence
import Observation

/// The user's corrections of a transcript: changed text, replaced words, joined or removed
/// passages, removed fillers, and the text of imported documents.
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

    /// Joins a passage with the one before it, e.g. when recognition split a sentence. The
    /// joined passage keeps the speaker of the first one.
    /// - Returns: Whether there was a passage before it.
    @discardableResult
    public func mergeWithPrevious(_ segmentID: TranscriptSegment.ID, in note: Note) async throws -> Bool {
        var segments = note.decodedTranscript()
        guard let index = segments.firstIndex(where: { $0.id == segmentID }), index > 0 else { return false }
        let segment = segments.remove(at: index)
        var previous = segments[index - 1]
        previous.text = [previous.text, segment.text].filter { !$0.isEmpty }.joined(separator: " ")
        let firstWord = segment.words.first.map { word in
            var spaced = word
            if !word.text.hasPrefix(" ") { spaced.text = " " + word.text }
            return spaced
        }
        previous.words += (firstWord.map { [$0] } ?? []) + segment.words.dropFirst()
        previous.end = max(previous.end, segment.end)
        segments[index - 1] = previous
        try await writer.save(segments, speakers: note.speakers, to: note, edited: true)
        return true
    }

    /// Replaces a word or phrase everywhere in the note, e.g. a name recognition got wrong.
    /// Whole words only; case is ignored unless `matchesCase`. The replacement keeps the
    /// timing of the words it replaces.
    /// - Returns: How many places were replaced.
    @discardableResult
    public func replace(_ search: String, with replacement: String, in note: Note, matchesCase: Bool = false) async throws -> Int {
        let finder = PhraseReplacement(search: search, replacement: replacement, matchesCase: matchesCase)
        guard let finder else { return 0 }
        guard note.kind.hasAudio else {
            let (text, count) = finder.apply(to: note.bodyText)
            guard count > 0 else { return 0 }
            try setText(text, of: note)
            return count
        }
        var total = 0
        let segments = note.decodedTranscript().compactMap { segment -> TranscriptSegment? in
            let (text, count) = finder.apply(to: segment.text)
            guard count > 0 else { return segment }
            total += count
            // A passage that consisted only of the removed words is removed.
            guard !text.isEmpty else { return nil }
            var corrected = segment
            corrected.text = text
            corrected.words = WordRetiming.retime(segment.words, to: text, from: segment.start, to: segment.end)
            return corrected
        }
        guard total > 0 else { return 0 }
        try await writer.save(segments, speakers: note.speakers, to: note, edited: true)
        return total
    }

    /// How many places `replace` would change.
    public func occurrences(of search: String, in note: Note, matchesCase: Bool = false) -> Int {
        guard let finder = PhraseReplacement(search: search, replacement: "", matchesCase: matchesCase) else { return 0 }
        guard note.kind.hasAudio else { return finder.count(in: note.bodyText) }
        return note.decodedTranscript().reduce(0) { $0 + finder.count(in: $1.text) }
    }

    /// Replaces the text of an imported document (PDF, photo), e.g. to fix what text
    /// recognition got wrong.
    public func setText(_ text: String, of note: Note) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.kind.hasAudio, trimmed != note.bodyText else { return }
        note.bodyText = trimmed
        note.transcriptEditedAt = .now
        try writer.store.save()
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

/// Finds a word or phrase as whole words and replaces it.
struct PhraseReplacement {
    private let expression: NSRegularExpression
    private let template: String

    /// `nil` for an empty search.
    init?(search: String, replacement: String, matchesCase: Bool) {
        let words = search.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { return nil }
        // Whole words: no letter or digit right before or after. Spaces in the phrase match
        // any run of whitespace.
        let pattern = #"(?<![\p{L}\p{N}])"# + words.joined(separator: #"\s+"#) + #"(?![\p{L}\p{N}])"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: matchesCase ? [] : [.caseInsensitive]) else { return nil }
        self.expression = expression
        template = NSRegularExpression.escapedTemplate(for: replacement.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func count(in text: String) -> Int {
        expression.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    func apply(to text: String) -> (text: String, count: Int) {
        let count = count(in: text)
        guard count > 0 else { return (text, 0) }
        let replaced = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        // Replacing with nothing leaves double spaces behind.
        let tidied = replaced.replacing(/\ {2,}/, with: " ").trimmingCharacters(in: .whitespaces)
        return (tidied, count)
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
