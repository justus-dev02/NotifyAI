//
//  SubtitleExporter.swift
//  NotifyAIExport
//

import Foundation
import NotifyAICore
import NotifyAISupport

/// Subtitles from a transcript, as SubRip (`.srt`) or WebVTT (`.vtt`).
///
/// Cues follow the usual reading rules: at most two lines of `maximumLineLength` characters
/// and at most `maximumDuration` seconds. Word timings decide where a cue ends; without them
/// a segment's time is shared by its words in proportion to their length. A speaker change
/// is shown at the start of the cue ("Anna: …" in SRT, a voice tag in WebVTT).
struct SubtitleExporter {
    enum Format: Sendable {
        case subRip
        case webVTT
    }

    struct Cue: Equatable, Sendable {
        var start: TimeInterval
        var end: TimeInterval
        var lines: [String]
        /// Set on the first cue after a speaker change.
        package var speaker: String?
    }

    static let maximumLineLength = 42
    static let maximumDuration: TimeInterval = 7
    /// Cues shorter than this cannot be read; they are extended into the following pause.
    static let minimumDuration: TimeInterval = 0.8

    func render(_ segments: [TranscriptSegment], as format: Format) -> String {
        let cues = cues(for: segments)
        switch format {
        case .subRip:
            return cues.enumerated().map { index, cue in
                let text = (cue.speaker.map { "\($0): " } ?? "") + cue.lines.joined(separator: "\n")
                return "\(index + 1)\n\(Self.timestamp(cue.start, separator: ",")) --> \(Self.timestamp(cue.end, separator: ","))\n\(text)\n"
            }
            .joined(separator: "\n")
        case .webVTT:
            let body = cues.map { cue in
                let text = (cue.speaker.map { "<v \(Self.escaped($0))>" } ?? "") + cue.lines.map(Self.escaped).joined(separator: "\n")
                return "\(Self.timestamp(cue.start, separator: ".")) --> \(Self.timestamp(cue.end, separator: "."))\n\(text)\n"
            }
            return (["WEBVTT\n"] + body).joined(separator: "\n")
        }
    }

    func cues(for segments: [TranscriptSegment]) -> [Cue] {
        var cues: [Cue] = []
        var previousSpeaker: String?
        for segment in Transcript.normalized(segments) {
            var isFirst = true
            for part in parts(of: segment) {
                let changesSpeaker = isFirst && segment.speaker != nil && segment.speaker != previousSpeaker
                cues.append(Cue(start: part.start, end: part.end, lines: Self.lines(part.text), speaker: changesSpeaker ? segment.speaker : nil))
                isFirst = false
            }
            previousSpeaker = segment.speaker
        }
        // Readable durations without overlapping the next cue.
        for index in cues.indices {
            let next = index + 1 < cues.count ? cues[index + 1].start : .infinity
            let wanted = max(cues[index].end, cues[index].start + Self.minimumDuration)
            cues[index].end = max(cues[index].start + 0.01, min(wanted, next))
        }
        return cues
    }

    // MARK: - Private

    private struct Token {
        package let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    /// The segment cut into pieces of at most two lines and `maximumDuration` seconds.
    private func parts(of segment: TranscriptSegment) -> [(text: String, start: TimeInterval, end: TimeInterval)] {
        let tokens = Self.tokens(of: segment)
        var parts: [(text: String, start: TimeInterval, end: TimeInterval)] = []
        var current: [Token] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            parts.append((current.map(\.text).joined(separator: " "), first.start, last.end))
            current = []
        }
        for token in tokens {
            let text = (current.map(\.text) + [token.text]).joined(separator: " ")
            let tooLong = text.count > 2 * Self.maximumLineLength
            let tooSlow = token.end - (current.first?.start ?? token.start) > Self.maximumDuration
            if !current.isEmpty, tooLong || tooSlow {
                flush()
            }
            current.append(token)
            // A sentence end is a good place for a cue to end.
            if let last = token.text.last, ".?!".contains(last), current.map(\.text).joined(separator: " ").count > Self.maximumLineLength {
                flush()
            }
        }
        flush()
        return parts
    }

    private static func tokens(of segment: TranscriptSegment) -> [Token] {
        if !segment.words.isEmpty {
            return segment.words.compactMap { word in
                let text = word.text.trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : Token(text: text, start: word.start, end: max(word.end, word.start))
            }
        }
        let words = segment.text.split(whereSeparator: \.isWhitespace).map(String.init)
        let characters = max(1, words.reduce(0) { $0 + $1.count })
        let duration = segment.end - segment.start
        var position = segment.start
        return words.map { word in
            let length = duration * Double(word.count) / Double(characters)
            defer { position += length }
            return Token(text: word, start: position, end: position + length)
        }
    }

    /// One or two lines, broken at the space closest to the middle.
    static func lines(_ text: String) -> [String] {
        guard text.count > maximumLineLength else { return [text] }
        let characters = Array(text)
        let middle = characters.count / 2
        let spaces = characters.indices.filter { characters[$0] == " " }
        guard let split = spaces.min(by: { abs($0 - middle) < abs($1 - middle) }) else { return [text] }
        return [String(characters[..<split]), String(characters[(split + 1)...])]
    }

    /// "00:01:02,345" (SRT) or "00:01:02.345" (WebVTT).
    static func timestamp(_ time: TimeInterval, separator: String) -> String {
        let milliseconds = Int((max(0, time) * 1_000).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = milliseconds / 60_000 % 60
        let seconds = milliseconds / 1_000 % 60
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, seconds, separator, milliseconds % 1_000)
    }

    /// WebVTT treats `<`, `>` and `&` as markup.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
