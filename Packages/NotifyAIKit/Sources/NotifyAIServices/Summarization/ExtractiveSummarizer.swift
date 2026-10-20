//
//  ExtractiveSummarizer.swift
//  NotifyAIServices
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
        let spoken = Self.sentences(in: request.text).filter { $0.text.count >= 12 }
        let sentences = spoken.map(\.text)
        guard !sentences.isEmpty else {
            throw SummarizationError.emptyInput
        }

        let cues = CueWords(languageCode: request.language.languageCode)
        let ranked = rank(sentences, markedPassages: request.markedPassages, languageCode: request.language.languageCode)
        let keyPointIndices = ranked.prefix(keyPointCount).sorted()
        let keyPoints = keyPointIndices.map { sentences[$0] }

        let decisions = sentences.filter { cues.matches($0, in: cues.decision) }
        let questions = sentences.filter { $0.hasSuffix("?") || cues.matches($0, in: cues.openQuestion) }
        let actionItems = spoken.compactMap { actionItem(in: $0, cues: cues, recordedAt: request.recordedAt) }

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

    // MARK: - Tasks

    /// The task a sentence states, if any.
    ///
    /// A commitment ("ich kümmere mich", "Ben übernimmt") is a task on its own, and so is
    /// something the speaker will do by a day ("Ich schicke es bis Freitag"). An obligation
    /// ("wir müssen", "das soll") only with a person or a deadline: otherwise "das muss man
    /// sagen" would become a task. Questions, hedged or conditional statements ("vielleicht",
    /// "falls", "könnten wir") and things already done are no tasks. A commitment in the first
    /// person belongs to the speaker of the line.
    private func actionItem(in sentence: SpokenSentence, cues: CueWords, recordedAt: Date) -> ActionItem? {
        let text = sentence.text
        guard !text.hasSuffix("?"), !cues.matches(text, in: cues.hedge), !cues.matches(text, in: cues.completed) else { return nil }
        let named = Self.owner(in: text)
        let isFirstPerson = cues.matches(text, in: cues.firstPerson)
        let hasDeadline = DeadlinePhrase.phrase(in: text, relativeTo: recordedAt) != nil
        let isCommitment = cues.matches(text, in: cues.commitment) || isFirstPerson && hasDeadline
        let isAssignedObligation = cues.matches(text, in: cues.obligation)
            && (named != nil || hasDeadline || cues.matches(text, in: cues.deadline))
        guard isCommitment || isAssignedObligation else { return nil }
        // "Ich schicke Frau Berger das Angebot": the speaker does it, not the person named.
        let owner = isFirstPerson ? sentence.speaker ?? named : named
        return ActionItem(task: Self.withoutLeadingFillers(text, cues: cues), owner: owner, evidence: text)
    }

    /// "Also, ja, ich schicke …" → "Ich schicke …".
    private static func withoutLeadingFillers(_ sentence: String, cues: CueWords) -> String {
        var words = sentence.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        while words.count > 3, let first = words.first,
              cues.leadingFillers.contains(first.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            words.removeFirst()
        }
        let text = words.joined(separator: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
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

    /// A sentence of the text with the speaker of its line.
    struct SpokenSentence {
        let text: String
        let speaker: String?
    }

    /// The sentences of the text. A line of a transcript with speakers starts with the
    /// speaker's label ("Anna: …"); every sentence of that line belongs to that speaker.
    static func sentences(in text: String) -> [SpokenSentence] {
        text.split(whereSeparator: \.isNewline).flatMap { line -> [SpokenSentence] in
            let (speaker, rest) = speakerLabel(of: String(line))
            return TextChunker.sentences(in: rest).map { SpokenSentence(text: $0, speaker: speaker) }
        }
    }

    /// Splits off a leading "Sprecher 1: " label added by speaker detection.
    private static func speakerLabel(of line: String) -> (speaker: String?, rest: String) {
        guard let colon = line.firstIndex(of: ":"), line.distance(from: line.startIndex, to: colon) <= 20 else {
            return (nil, line)
        }
        let label = line[..<colon].trimmingCharacters(in: .whitespaces)
        let rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return (label.isEmpty ? nil : label, rest)
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
    /// Someone takes on a task.
    let commitment: [String]
    /// Something has to be done; a task only with a person or a deadline.
    let obligation: [String]
    let deadline: [String]
    let openQuestion: [String]
    /// The speaker talks about themselves ("ich", "mache ich").
    let firstPerson: [String]
    /// Hedged or conditional: an idea, not a task.
    let hedge: [String]
    /// Already done: no longer a task.
    let completed: [String]
    /// Words a spoken sentence often starts with that belong to no task.
    let leadingFillers: Set<String>

    init(languageCode: String) {
        if languageCode == "de" {
            decision = ["beschlossen", "entschieden", "vereinbart", "festgelegt", "geeinigt", "abgemacht", "beschluss", "einigen uns"]
            commitment = [
                "ich werde", "werde ich", "übernimmt", "übernehme", "übernehmen", "kümmert sich", "kümmere mich",
                "kümmern uns", "mache ich", "erledige ich", "schicke ich", "kläre ich", "aufgabe", "todo", "to-do",
            ]
            obligation = ["muss", "müssen", "soll", "sollen", "werden wir", "bitte"]
            deadline = [
                "bis", "morgen", "übermorgen", "heute", "nächste woche", "nächsten woche", "montag", "dienstag",
                "mittwoch", "donnerstag", "freitag", "samstag", "sonntag", "ende der woche", "monatsende",
            ]
            openQuestion = ["unklar", "offen", "klären", "prüfen", "risiko", "problem", "bedenken"]
            firstPerson = ["ich", "mich", "mir"]
            hedge = [
                "vielleicht", "eventuell", "evtl", "könnte", "könnten", "würde", "würden", "falls", "irgendwann",
                "möglicherweise", "theoretisch", "überlegen",
            ]
            completed = ["schon erledigt", "bereits erledigt", "ist erledigt", "habe ich schon", "hab ich schon", "haben wir schon", "wurde schon"]
            leadingFillers = ["also", "ja", "okay", "ok", "gut", "genau", "und", "dann", "so", "na", "naja", "äh", "ähm"]
        } else {
            decision = ["decided", "agreed", "decision", "concluded", "approved", "settled"]
            commitment = [
                "i will", "i'll", "will take care", "take care of", "takes care of", "follow up", "action item",
                "todo", "to-do", "is going to", "i am going to", "i'm going to",
            ]
            obligation = ["must", "should", "needs to", "need to", "we will", "we'll", "please"]
            deadline = [
                "by", "until", "tomorrow", "today", "next week", "monday", "tuesday", "wednesday", "thursday",
                "friday", "saturday", "sunday", "end of the week", "end of the month",
            ]
            openQuestion = ["unclear", "open question", "not sure", "risk", "issue", "concern", "clarify"]
            firstPerson = ["i", "i'll", "i'm", "me", "myself"]
            hedge = ["maybe", "perhaps", "might", "could", "would", "someday", "possibly"]
            completed = ["already done", "already did", "already sent", "have already", "has already", "is done"]
            leadingFillers = ["so", "okay", "ok", "well", "yeah", "yes", "and", "then", "alright", "right", "um", "uh"]
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
