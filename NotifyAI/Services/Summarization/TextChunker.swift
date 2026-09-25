//
//  TextChunker.swift
//  NotifyAI
//

import Foundation
import NaturalLanguage

/// Splits long text into pieces that fit into a language model's context window.
///
/// Cuts happen at sentence boundaries whenever possible, so no chunk starts or ends
/// in the middle of a thought. Sentences longer than the budget are split at word
/// boundaries as a last resort.
struct TextChunker: Sendable {
    /// Returns the size of a text in tokens (or any other unit the budget uses).
    typealias Measure = @Sendable (String) async -> Int

    let budget: Int
    let measure: Measure

    /// A conservative character-based estimate: the on-device tokenizer averages
    /// roughly three characters per token for German and English text.
    static let estimatedTokens: Measure = { text in
        Int((Double(text.count) / 3).rounded(.up))
    }

    init(budget: Int, measure: @escaping Measure = TextChunker.estimatedTokens) {
        precondition(budget > 0, "The budget must be positive.")
        self.budget = budget
        self.measure = measure
    }

    func chunks(of text: String) async -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if await measure(trimmed) <= budget {
            return [trimmed]
        }

        // Every unit is measured once and sizes are summed. Token counts are nearly
        // additive; callers keep a safety margin in `budget` for the joins.
        var chunks: [String] = []
        var current: [String] = []
        var currentSize = 0
        for (unit, size) in await measuredUnits(of: trimmed) {
            if currentSize + size > budget, !current.isEmpty {
                chunks.append(current.joined(separator: " "))
                current = []
                currentSize = 0
            }
            current.append(unit)
            currentSize += size
        }
        if !current.isEmpty {
            chunks.append(current.joined(separator: " "))
        }
        return chunks
    }

    /// Sentences with their sizes; over-long sentences are broken into word groups.
    private func measuredUnits(of text: String) async -> [(String, Int)] {
        var units: [(String, Int)] = []
        for sentence in Self.sentences(in: text) {
            let size = await measure(sentence)
            if size <= budget {
                units.append((sentence, size))
            } else {
                units.append(contentsOf: await wordGroups(of: sentence))
            }
        }
        return units
    }

    private func wordGroups(of sentence: String) async -> [(String, Int)] {
        var groups: [(String, Int)] = []
        var current: [Substring] = []
        var currentSize = 0
        for word in sentence.split(whereSeparator: \.isWhitespace) {
            let size = await measure(String(word))
            if currentSize + size > budget, !current.isEmpty {
                groups.append((current.joined(separator: " "), currentSize))
                current = []
                currentSize = 0
            }
            current.append(word)
            currentSize += size
        }
        if !current.isEmpty {
            groups.append((current.joined(separator: " "), currentSize))
        }
        return groups
    }

    static func sentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return true
        }
        return sentences
    }
}
