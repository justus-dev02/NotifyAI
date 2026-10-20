//
//  ActionItemRefiner.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore

/// Makes the tasks of a summary precise enough to act on.
///
/// Summarizers find too many tasks and describe them too vaguely: topics become tasks
/// ("Nächste Schritte besprechen"), one task appears three times in different words, the
/// owner is "ich" or "wir", and a deadline said in the same sentence is missing. The refiner
/// runs after every summarizer and keeps a task only if
///
/// - it says what is to be done (at least one word that is not a generic one such as
///   "besprechen", "Thema" or "nächste Schritte"), and
/// - the text supports it: the quote the model cited, or else the task itself, matches a
///   passage of the text (most of its content words occur there, compared by their first
///   five letters).
///
/// The matching passage then gives the task its owner where the task says "ich" (the speaker
/// of that passage), a deadline said there and its position in the recording. Tasks that
/// describe the same thing are merged.
struct ActionItemRefiner: Sendable {
    /// A place of the text a task can be checked against.
    struct Passage: Sendable {
        let text: String
        let terms: Set<String>
        /// The speaker of the passage, if the transcript has speakers.
        let speaker: String?
        /// Where it starts in the recording; `nil` for documents.
        let start: TimeInterval?
    }

    /// Share of a quote's words that must occur in the passage.
    static let minimumQuoteOverlap = 0.6
    /// Share of a task's words that must occur in the passage when no quote matches.
    static let minimumTaskOverlap = 0.5

    let languageCode: String
    /// Participants and speaker labels, spelled as the user knows them.
    let people: [String]
    let passages: [Passage]
    let recordedAt: Date

    init(text: String, segments: [TranscriptSegment], languageCode: String, people: [String], recordedAt: Date) {
        self.languageCode = languageCode
        self.people = people
        self.recordedAt = recordedAt
        passages = Self.passages(text: text, segments: segments, languageCode: languageCode)
    }

    /// The refined tasks with the recording positions that support them, by task text.
    func refine(_ items: [ActionItem]) -> (items: [ActionItem], sourceTimes: [String: TimeInterval]) {
        var refined: [ActionItem] = []
        var sourceTimes: [String: TimeInterval] = [:]
        for item in items {
            guard let task = Self.cleanedTask(item.task), isSpecific(task),
                  let passage = support(for: item, task: task)
            else { continue }
            var result = item
            result.task = task
            result.owner = owner(item.owner, speaker: passage.speaker)
            result.due = SummaryGrounding.cleaned(item.due).map(Self.withoutDeadlineWord)
                ?? DeadlinePhrase.phrase(in: item.evidence ?? passage.text, relativeTo: recordedAt)
            if let index = refined.firstIndex(where: { TaskIdentity.matches($0.task, task) }) {
                refined[index] = Self.merged(refined[index], result)
                continue
            }
            refined.append(result)
            if let start = passage.start {
                sourceTimes[task] = start
            }
        }
        return (refined, sourceTimes)
    }

    // MARK: - Task text

    /// The task without list markers, labels and trailing punctuation, starting with a capital
    /// letter; `nil` when nothing is left.
    static func cleanedTask(_ text: String) -> String? {
        var task = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = task.firstMatch(of: /^(?:[-•*–]\s*|\d+[.)]\s*|(?i:task|aufgabe|todo|to-do|action item)\s*:\s*)+/) {
            task.removeSubrange(match.range)
        }
        task = task.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".;,")))
        guard let first = task.first else { return nil }
        return first.uppercased() + task.dropFirst()
    }

    /// Whether the task names something to do beyond generic words.
    func isSpecific(_ task: String) -> Bool {
        let terms = TextAnalysis.terms(in: task, languageCode: languageCode)
        return terms.count >= 2 && terms.contains { !Self.genericTerms.contains($0) }
    }

    /// Words that make up vague tasks ("Nächste Schritte besprechen", "Follow up on things").
    static let genericTerms: Set<String> = Set([
        "nachste", "naechste", "schritt", "schritte", "thema", "themen", "punkt", "punkte", "besprechen",
        "sprechen", "reden", "diskutieren", "weitermachen", "weiter", "machen", "tun", "erledigen", "kummern",
        "klaren", "angehen", "schauen", "anschauen", "uberlegen", "nachdenken", "sache", "sachen", "ding", "dinge",
        "alles", "etwas", "dran", "darum", "dazu", "daruber", "vorgehen", "weiteres", "umsetzung", "umsetzen",
        "next", "step", "steps", "topic", "topics", "point", "points", "discuss", "talk", "follow", "continue",
        "work", "look", "into", "think", "things", "stuff", "item", "items", "everything", "something", "handle",
        "do", "make", "about", "further", "implement", "implementation",
    ].map(TextAnalysis.stem))

    // MARK: - Support in the text

    /// The passage that supports the task: the best match of its quote, or else of the task.
    private func support(for item: ActionItem, task: String) -> Passage? {
        if let evidence = item.evidence, let passage = bestPassage(for: evidence, minimumOverlap: Self.minimumQuoteOverlap) {
            return passage
        }
        return bestPassage(for: task, minimumOverlap: Self.minimumTaskOverlap)
    }

    private func bestPassage(for statement: String, minimumOverlap: Double) -> Passage? {
        let terms = Self.terms(in: statement, languageCode: languageCode)
        guard !terms.isEmpty else { return nil }
        // Two shared words at least, unless the statement has only one.
        let minimumShared = min(2, terms.count)
        var best: (score: Double, passage: Passage)?
        for passage in passages {
            let shared = terms.intersection(passage.terms).count
            let score = Double(shared) / Double(terms.count)
            guard shared >= minimumShared, score >= minimumOverlap, score > (best?.score ?? 0) else { continue }
            best = (score, passage)
        }
        return best?.passage
    }

    /// Single segments (they carry the speaker) and pairs of consecutive ones (statements span
    /// segment boundaries); for documents, sentences and pairs of sentences.
    static func passages(text: String, segments: [TranscriptSegment], languageCode: String) -> [Passage] {
        func passage(_ text: String, speaker: String?, start: TimeInterval?) -> Passage {
            Passage(text: text, terms: terms(in: text, languageCode: languageCode), speaker: speaker, start: start)
        }
        guard segments.isEmpty else {
            let singles = segments.map { passage($0.text, speaker: $0.speaker, start: $0.start) }
            let pairs = zip(segments, segments.dropFirst()).map { first, second in
                passage(first.text + " " + second.text, speaker: first.speaker == second.speaker ? first.speaker : nil, start: first.start)
            }
            return singles + pairs
        }
        let sentences = TextChunker.sentences(in: text)
        let singles = sentences.map { passage($0, speaker: nil, start: nil) }
        let pairs = zip(sentences, sentences.dropFirst()).map { passage($0 + " " + $1, speaker: nil, start: nil) }
        return singles + pairs
    }

    /// The content words of a statement, cut to five letters: a task names the action in
    /// another form than the conversation ("liefern" for "liefert", "schicken" for "schicke").
    static func terms(in text: String, languageCode: String) -> Set<String> {
        let stopWords = SearchStopWords.words(for: languageCode)
        return Set(TextAnalysis.normalizedWords(in: text).compactMap { word in
            guard word.count >= 2, !stopWords.contains(word) else { return nil }
            return String(word.prefix(5))
        })
    }

    // MARK: - Owner

    /// The owner as a person: "ich" becomes the speaker who said it, "wir" and "du" (nobody
    /// in particular) are dropped, and a first name becomes the full name of a participant.
    func owner(_ owner: String?, speaker: String?) -> String? {
        guard let owner = SummaryGrounding.cleaned(owner) else { return nil }
        let key = TextAnalysis.key(owner)
        let userLabel = SourceSpeakerAttribution.userLabel
        if Self.firstPerson.contains(key) || key == TextAnalysis.key(userLabel) {
            // The speaker of the quoted line; without speakers only the user's own label is certain.
            return speaker ?? (people.contains(userLabel) && key == TextAnalysis.key(userLabel) ? userLabel : nil)
        }
        if Self.otherPronouns.contains(key) {
            return nil
        }
        if let exact = people.first(where: { TextAnalysis.key($0) == key }) {
            return exact
        }
        let byFirstName = people.filter { TextAnalysis.normalizedWords(in: $0).first == key }
        return byFirstName.count == 1 ? byFirstName[0] : owner
    }

    private static let firstPerson: Set<String> = ["ich", "mich", "mir", "i", "me", "myself"]
    private static let otherPronouns: Set<String> = [
        "wir", "uns", "du", "dich", "dir", "ihr", "euch", "sie", "man", "alle", "jemand", "team",
        "we", "us", "you", "they", "everyone", "everybody", "someone", "somebody", "all",
    ]

    // MARK: - Merging

    /// One task from two that describe the same thing: the more detailed wording, and owner,
    /// deadline and state from whichever has them.
    private static func merged(_ first: ActionItem, _ second: ActionItem) -> ActionItem {
        var result = first
        if second.task.count > first.task.count, first.owner == nil || second.owner != nil {
            result.task = second.task
        }
        result.owner = first.owner ?? second.owner
        result.due = first.due ?? second.due
        result.isDone = first.isDone || second.isDone
        return result
    }

    /// "bis Freitag" → "Freitag": the app shows deadlines as "bis …".
    static func withoutDeadlineWord(_ due: String) -> String {
        guard let match = due.firstMatch(of: /^(?i:bis|spätestens|by|until|before)\s+/) else { return due }
        let rest = due[match.range.upperBound...]
        return rest.isEmpty ? due : String(rest)
    }
}

/// Finds a deadline in a sentence ("bis Freitag", "bis zum 3. Oktober", "by next week").
enum DeadlinePhrase {
    /// The first phrase that names a day, without "bis"/"by" ("Freitag", "nächste Woche").
    static func phrase(in text: String, relativeTo reference: Date, resolver: DueDateResolver = DueDateResolver()) -> String? {
        for pattern in patterns {
            for match in text.matches(of: pattern) where !isGreetingOrPast(before: match.range, in: text) {
                let phrase = String(text[match.range]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                if resolver.resolve(phrase, relativeTo: reference) != nil {
                    return ActionItemRefiner.withoutDeadlineWord(phrase)
                }
            }
        }
        return nil
    }

    /// "Guten Morgen" and "heute Morgen" name no deadline.
    private static func isGreetingOrPast(before range: Range<String.Index>, in text: String) -> Bool {
        let before = text[..<range.lowerBound].lowercased()
        return ["guten ", "gestern ", "heute ", "good "].contains { before.hasSuffix($0) }
    }

    /// Most specific first: explicit dates, then "bis" with a day, then words on their own.
    private static var patterns: [Regex<Substring>] {
        [
            // bis (zum) 3. Oktober, bis 3.10., by the 3rd
            /(?i)\b(?:bis|spätestens|by|until|before)\s+(?:(?:zum|zur|the|spätestens)\s+)?\d{1,2}\.?\s*(?:\d{1,2}\.(?:\d{2,4})?|[a-zäöü]+)/,
            // by October 3
            /(?i)\b(?:by|until|before)\s+[a-z]+\s+\d{1,2}(?:st|nd|rd|th)?/,
            // bis Freitag, bis nächste Woche, bis Ende des Monats, by the end of the week
            #/
            (?i) \b (?:bis|spätestens|by|until|before) \s+
            (?: (?:zum|zur|kommende[nrs]?|nächste[nrs]?|diese[nrs]?|ende|der|des|the|end|of|next|this) \s+ ){0,4}
            (?: montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonntag
              | monday|tuesday|wednesday|thursday|friday|saturday|sunday
              | morgen|übermorgen|heute|woche|monat|monats|monatsende|wochenende|tomorrow|today|week|month ) \b
            /#,
            // morgen, nächste Woche, tomorrow, without "bis"
            /(?i)\b(?:übermorgen|morgen|nächste woche|kommende woche|tomorrow|next week)\b/,
        ]
    }
}
