//
//  TranscriptCleanup.swift
//  NotifyAITranscription
//

import Foundation
import NotifyAICore
import NotifyAISupport

/// Removes filler words ("äh", "ähm", "uh", "um") from a transcript.
///
/// Only standalone fillers are removed, with the comma or dash that belongs to them; a
/// sentence that started with a filler starts with a capital letter again. Words that only
/// contain a filler ("Hummel", "umfassend") are never touched. The lists are per language:
/// "um" is a filler in English but a preposition in German ("um 10 Uhr"), "er" and "eh" are
/// German words. Word timings of the remaining words stay as they are.
package struct FillerWords: Sendable {
    let words: Set<String>

    package init(languageCode: String) {
        words = switch languageCode {
        case "de": ["äh", "ähm", "ähh", "ähhm", "öhm", "ehm", "hm", "hmm", "mhm", "mmh"]
        case "en": ["uh", "uhm", "um", "umm", "erm", "hm", "hmm", "mhm", "mm"]
        case "fr": ["euh", "heu", "hum", "hmm"]
        case "es": ["ehm", "hmm", "mmm"]
        case "it": ["ehm", "uhm", "mmm", "hmm"]
        default: ["hmm", "mhm"]
        }
    }

    func isFiller(_ word: String) -> Bool {
        let core = word.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return words.contains(core.lowercased())
    }

    /// The segments without fillers; segments that consisted only of fillers are dropped.
    package func remove(from segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.compactMap(remove(from:))
    }

    package func remove(from segment: TranscriptSegment) -> TranscriptSegment? {
        if segment.words.isEmpty {
            let text = cleaned(segment.text.split(separator: " ", omittingEmptySubsequences: true).map(String.init))
            guard !text.isEmpty else { return nil }
            var result = segment
            result.text = text
            return result
        }
        var kept: [TranscriptWord] = []
        var capitalizeNext = false
        for (index, word) in segment.words.enumerated() {
            let core = word.text.trimmingCharacters(in: .whitespaces)
            if isFiller(core) {
                // "Äh, wir …" at the start of a sentence: the next word starts it.
                let startsSentence = kept.isEmpty || kept.last.map { Self.endsSentence($0.text) } == true
                if startsSentence, core.first?.isUppercase == true { capitalizeNext = true }
                if let last = kept.indices.last {
                    if let mark = core.last, ".?!".contains(mark) {
                        // A filler that ended its sentence ("…, äh.") hands its punctuation over.
                        kept[last].text = Self.strippingTrailingComma(kept[last].text) + String(mark)
                    } else if word.text.hasSuffix(",") {
                        // "gehen, äh, morgen": the commas around the filler go with it.
                        kept[last].text = Self.strippingTrailingComma(kept[last].text)
                    }
                }
                continue
            }
            var word = word
            if capitalizeNext {
                word.text = Self.capitalizingFirstLetter(word.text)
                capitalizeNext = false
            }
            if kept.isEmpty, index > 0 {
                // The first word of the segment carries no leading space; between two kept
                // words the space of the removed filler went with it.
                word.text = word.text.trimmingCharacters(in: .whitespaces)
            }
            kept.append(word)
        }
        guard let first = kept.first, let last = kept.last else { return nil }
        var result = segment
        result.words = kept
        result.text = kept.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if first.start > segment.start { result.start = first.start }
        result.end = max(result.start, min(segment.end, max(last.end, result.start)))
        return result
    }

    /// Text without fillers, for segments without word timings.
    private func cleaned(_ tokens: [String]) -> String {
        var kept: [String] = []
        var capitalizeNext = false
        for token in tokens {
            if isFiller(token) {
                if kept.isEmpty || Self.endsSentence(kept.last ?? ""), token.first?.isUppercase == true { capitalizeNext = true }
                if !kept.isEmpty {
                    if let mark = token.last, ".?!".contains(mark) {
                        kept[kept.count - 1] = Self.strippingTrailingComma(kept[kept.count - 1]) + String(mark)
                    } else if token.hasSuffix(",") {
                        kept[kept.count - 1] = Self.strippingTrailingComma(kept[kept.count - 1])
                    }
                }
                continue
            }
            kept.append(capitalizeNext ? Self.capitalizingFirstLetter(token) : token)
            capitalizeNext = false
        }
        return kept.joined(separator: " ")
    }

    private static func endsSentence(_ word: String) -> Bool {
        word.trimmingCharacters(in: .whitespaces).last.map { ".?!".contains($0) } ?? false
    }

    private static func strippingTrailingComma(_ word: String) -> String {
        var word = word
        while let last = word.last, last == "," || last == "–" || last == "-" {
            word.removeLast()
        }
        return word
    }

    private static func capitalizingFirstLetter(_ word: String) -> String {
        guard let index = word.firstIndex(where: \.isLetter) else { return word }
        return word.replacingCharacters(in: index...index, with: word[index].uppercased())
    }
}

/// Words and names the recognizer should know: product names, people, technical terms.
///
/// Whisper receives them as a prompt and Apple Speech as contextual strings; both then prefer
/// these spellings. Parakeet has no such input, so its result is corrected afterwards: a word
/// that is almost a term (one or two letters off, same first letter, at least five letters)
/// is replaced by the term. The thresholds are strict on purpose: correcting a word that was
/// right is worse than missing a correction.
package struct CustomVocabulary: Equatable, Sendable {
    let terms: [String]

    package init(_ terms: [String]) {
        var seen = Set<String>()
        self.terms = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    var isEmpty: Bool { terms.isEmpty }

    /// The prompt for Whisper: the terms as a comma-separated list, at most about 100 tokens.
    var prompt: String? {
        guard !terms.isEmpty else { return nil }
        var prompt = ""
        for term in terms {
            let next = prompt.isEmpty ? term : prompt + ", " + term
            guard next.count <= 400 else { break }
            prompt = next
        }
        return " " + prompt + "."
    }

    /// The segments with near-misses of a single-word term replaced by the term.
    func corrected(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let candidates = terms.filter { !$0.contains(" ") && $0.count >= 5 }
        guard !candidates.isEmpty else { return segments }
        return segments.map { segment in
            var segment = segment
            if segment.words.isEmpty {
                segment.text = segment.text.split(separator: " ", omittingEmptySubsequences: false)
                    .map { correct(String($0), candidates: candidates) }
                    .joined(separator: " ")
            } else {
                segment.words = segment.words.map { word in
                    var word = word
                    word.text = correct(word.text, candidates: candidates)
                    return word
                }
                segment.text = segment.words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return segment
        }
    }

    /// `token` (with its spaces and punctuation) with its core replaced by a matching term.
    private func correct(_ token: String, candidates: [String]) -> String {
        let leading = token.prefix { $0.isWhitespace || $0.isPunctuation }
        let trailing = token.reversed().prefix { $0.isWhitespace || $0.isPunctuation }
        guard leading.count + trailing.count < token.count else { return token }
        let core = String(token.dropFirst(leading.count).dropLast(trailing.count))
        guard core.count >= 5 else { return token }
        let folded = core.lowercased()
        var best: (term: String, distance: Int)?
        for term in candidates {
            let target = term.lowercased()
            guard target != folded, target.first == folded.first, abs(target.count - folded.count) <= 2 else { continue }
            let distance = Self.editDistance(folded, target)
            let allowed = target.count >= 8 ? 2 : 1
            if distance <= allowed, distance < (best?.distance ?? .max) {
                best = (term, distance)
            }
        }
        guard let best else { return token }
        return String(leading) + best.term + String(trailing.reversed())
    }

    /// Levenshtein distance of two short strings.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for (row, character) in a.enumerated() {
            var current = [row + 1] + Array(repeating: 0, count: b.count)
            for (column, other) in b.enumerated() {
                current[column + 1] = min(previous[column + 1] + 1, current[column] + 1, previous[column] + (character == other ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
