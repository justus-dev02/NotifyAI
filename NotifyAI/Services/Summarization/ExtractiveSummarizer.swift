//
//  ExtractiveSummarizer.swift
//  NotifyAI
//

import Foundation
import NaturalLanguage
import NotifyAICore

/// A summarizer without a language model, used when Apple Intelligence is unavailable.
///
/// It does not write new text. It selects the most informative sentences (term frequency
/// weighted, with a bonus for passages the user marked) and sorts sentences into decisions,
/// tasks and open questions using cue words. The UI labels the result accordingly.
struct ExtractiveSummarizer: Summarizer {
    private let keyPointCount = 5

    func summarize(_ request: SummaryRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> NoteSummary {
        let sentences = TextChunker.sentences(in: request.text)
            .map { Self.removingSpeakerLabel(from: $0) }
            .filter { $0.count >= 12 }
        guard !sentences.isEmpty else {
            throw SummarizationError.emptyInput
        }

        let cues = CueWords(languageCode: request.language.languageCode)
        let ranked = rank(sentences, markedPassages: request.markedPassages, languageCode: request.language.languageCode)
        let keyPointIndices = ranked.prefix(keyPointCount).sorted()
        let keyPoints = keyPointIndices.map { sentences[$0] }

        let decisions = sentences.filter { cues.matches($0, in: cues.decision) }
        let questions = sentences.filter { $0.hasSuffix("?") || cues.matches($0, in: cues.openQuestion) }
        let actionItems = sentences
            .filter { cues.matches($0, in: cues.action) && !$0.hasSuffix("?") }
            .map { ActionItem(task: $0, owner: Self.owner(in: $0)) }

        progress(1)
        return NoteSummary(
            overview: ranked.prefix(2).sorted().map { sentences[$0] }.joined(separator: " "),
            keyPoints: keyPoints,
            decisions: Array(decisions.prefix(6)),
            actionItems: Array(actionItems.prefix(10)),
            openQuestions: Array(questions.prefix(5)),
            topics: topics(in: request.text, sentences: sentences),
            source: .extractive,
            keywords: TextAnalysis.keywords(in: request.text, languageCode: request.language.languageCode, limit: 3)
        )
    }

    // MARK: - Ranking

    /// Indices of `sentences`, most informative first.
    private func rank(_ sentences: [String], markedPassages: [String], languageCode: String) -> [Int] {
        let stopWords = StopWords.words(for: languageCode)
        let tokenized = sentences.map { Self.words(in: $0).filter { $0.count > 2 && !stopWords.contains($0) } }

        var frequency: [String: Int] = [:]
        for words in tokenized {
            for word in words {
                frequency[word, default: 0] += 1
            }
        }
        let markedText = markedPassages.joined(separator: " ").lowercased()

        let scores = tokenized.enumerated().map { index, words -> Double in
            guard !words.isEmpty else { return 0 }
            let termScore = words.reduce(0.0) { $0 + Double(frequency[$1, default: 0]) }
            // Dividing by the square root favours informative sentences without
            // simply preferring the longest ones.
            var score = termScore / Double(words.count).squareRoot()
            if !markedText.isEmpty, markedText.contains(sentences[index].lowercased().prefix(40)) {
                score *= 2
            }
            return score
        }
        return scores.indices.sorted { scores[$0] > scores[$1] }
    }

    /// Frequent nouns become topics, each with the first sentences that mention them.
    private func topics(in text: String, sentences: [String]) -> [SummaryTopic] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var counts: [String: Int] = [:]
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            if tag == .noun {
                let noun = String(text[range])
                if noun.count > 3 {
                    counts[noun, default: 0] += 1
                }
            }
            return true
        }

        return counts
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(4)
            .map { noun, _ in
                let points = sentences.filter { $0.localizedCaseInsensitiveContains(noun) }.prefix(3)
                return SummaryTopic(title: noun, points: Array(points))
            }
    }

    // MARK: - Helpers

    private static func words(in sentence: String) -> [String] {
        sentence.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
    }

    /// Removes a leading "Sprecher 1: " label added by speaker detection.
    private static func removingSpeakerLabel(from sentence: String) -> String {
        guard let colon = sentence.firstIndex(of: ":"), sentence.distance(from: sentence.startIndex, to: colon) <= 20 else {
            return sentence
        }
        return String(sentence[sentence.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }

    /// The first person name in the sentence, detected with the system's named entity recognizer.
    private static func owner(in sentence: String) -> String? {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = sentence
        var owner: String?
        tagger.enumerateTags(
            in: sentence.startIndex..<sentence.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            if tag == .personalName {
                owner = String(sentence[range])
                return false
            }
            return true
        }
        return owner
    }
}

/// Cue words that indicate decisions, tasks and open questions.
private struct CueWords {
    let decision: [String]
    let action: [String]
    let openQuestion: [String]

    init(languageCode: String) {
        if languageCode == "de" {
            decision = ["beschlossen", "entschieden", "vereinbart", "festgelegt", "geeinigt", "abgemacht", "beschluss", "einigen uns"]
            action = [
                "muss", "müssen", "soll", "sollen", "werde", "werden wir", "übernimmt", "übernehme",
                "kümmert sich", "kümmere mich", "erledigt", "aufgabe", "todo", "to-do", "bis zum", "bis nächste",
            ]
            openQuestion = ["unklar", "offen", "klären", "prüfen", "risiko", "problem", "bedenken"]
        } else {
            decision = ["decided", "agreed", "decision", "concluded", "approved", "settled"]
            action = [
                "i will", "we will", "i'll", "we'll", "must", "should", "needs to", "need to",
                "take care of", "follow up", "action item", "todo", "to-do",
            ]
            openQuestion = ["unclear", "open question", "not sure", "risk", "issue", "concern", "clarify"]
        }
    }

    /// Matches whole words only ("problem" does not match "Problembehandlung") and ignores
    /// negated cues such as "kein Problem" or "nicht entschieden".
    func matches(_ sentence: String, in cues: [String]) -> Bool {
        let lowered = sentence.lowercased()
        return cues.contains { cue in
            let escaped = NSRegularExpression.escapedPattern(for: cue)
            guard lowered.range(of: "\\b\(escaped)\\b", options: .regularExpression) != nil else { return false }
            // A negation up to two words before the cue cancels it.
            let negated = "\\b(?:\(Self.negations))\\s+(?:\\w+\\s+)?\(escaped)\\b"
            return lowered.range(of: negated, options: .regularExpression) == nil
        }
    }

    private static let negations = ["kein", "keine", "keinen", "keinem", "keiner", "nicht", "nie", "ohne", "no", "not", "never", "without"]
        .joined(separator: "|")
}

private enum StopWords {
    static func words(for languageCode: String) -> Set<String> {
        languageCode == "de" ? german : english
    }

    private static let german: Set<String> = [
        "und", "oder", "aber", "der", "die", "das", "den", "dem", "des", "ein", "eine", "einer", "einem", "einen",
        "ist", "sind", "war", "waren", "hat", "haben", "wir", "ihr", "sie", "ich", "du", "es", "nicht", "auch",
        "mit", "für", "auf", "von", "zu", "im", "in", "an", "als", "wie", "dass", "noch", "schon", "dann", "also",
        "mal", "ja", "nein", "so", "was", "wenn", "man", "nach", "bei", "aus", "um", "über", "sich", "sein", "wird",
    ]

    private static let english: Set<String> = [
        "the", "and", "or", "but", "a", "an", "is", "are", "was", "were", "has", "have", "we", "you", "they", "i",
        "it", "not", "also", "with", "for", "on", "of", "to", "in", "at", "as", "that", "this", "then", "so",
        "what", "if", "by", "from", "about", "just", "like", "yeah", "okay", "be", "will",
    ]
}
