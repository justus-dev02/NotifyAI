//
//  QueryPlanner.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore

/// A relative time frame mentioned in a question.
enum Timeframe: String, CaseIterable, Sendable {
    case none, today, yesterday, thisWeek, lastWeek, thisMonth, lastMonth, thisYear, lastYear

    /// The date range, computed with the calendar (never by the language model).
    func dateRange(now: Date, calendar: Calendar) -> DateInterval? {
        func interval(_ component: Calendar.Component, offset: Int) -> DateInterval? {
            guard let shifted = calendar.date(byAdding: component, value: offset, to: now) else { return nil }
            return calendar.dateInterval(of: component, for: shifted)
        }
        return switch self {
        case .none: nil
        case .today: interval(.day, offset: 0)
        case .yesterday: interval(.day, offset: -1)
        case .thisWeek: interval(.weekOfYear, offset: 0)
        case .lastWeek: interval(.weekOfYear, offset: -1)
        case .thisMonth: interval(.month, offset: 0)
        case .lastMonth: interval(.month, offset: -1)
        case .thisYear: interval(.year, offset: 0)
        case .lastYear: interval(.year, offset: -1)
        }
    }

    var title: String {
        switch self {
        case .none: ""
        case .today: String(localized: "Heute", bundle: .module)
        case .yesterday: String(localized: "Gestern", bundle: .module)
        case .thisWeek: String(localized: "Diese Woche", bundle: .module)
        case .lastWeek: String(localized: "Letzte Woche", bundle: .module)
        case .thisMonth: String(localized: "Dieser Monat", bundle: .module)
        case .lastMonth: String(localized: "Letzter Monat", bundle: .module)
        case .thisYear: String(localized: "Dieses Jahr", bundle: .module)
        case .lastYear: String(localized: "Letztes Jahr", bundle: .module)
        }
    }
}

/// How a question is searched: the content to look for and the filters it implies.
struct QueryPlan: Equatable, Sendable {
    var searchText: String
    var expansions: [String] = []
    var filters = SearchFilters()
    /// Human-readable filters for the UI ("Person: Anna", "Letzte Woche").
    var filterDescriptions: [String] = []
    /// The user wants a list of notes ("Zeig mir alle Meetings mit Anna") rather than an answer.
    var wantsList = false
    /// The user wants one summary across the notes found ("Fasse alle Samsung-Meetings zusammen").
    var wantsCollectionSummary = false
}

/// Understands dates, labels, people, note kinds and focus in questions with deterministic rules.
///
/// Works without Apple Intelligence and is also used to check the language model's plan:
/// rules win where they are certain (explicit time expressions, known names).
struct RuleBasedQueryParser: Sendable {
    var now: Date = .now
    var calendar: Calendar = .current

    func plan(for question: String, knownPersons: [String], knownLabels: [String] = []) -> QueryPlan {
        let folded = " " + TextAnalysis.normalizedWords(in: question).joined(separator: " ") + " "
        var plan = QueryPlan(searchText: question)
        var removable: [String] = []

        // Labels the user gave notes ("Samsung: Was wurde zum Budget entschieden?"). A label
        // limits the search to its notes and is no search term: a note labeled "Samsung"
        // rarely says "Samsung".
        let labels = Self.labels(in: folded, knownLabels: knownLabels)
        if !labels.isEmpty {
            plan.filters.labels = labels
            plan.filterDescriptions += labels.map { String(localized: "Label: \($0)", bundle: .module) }
            removable += labels
        }
        let labelWords = Set(labels.flatMap(TextAnalysis.normalizedWords(in:)))

        // Time.
        if let (range, title, phrase) = dateRange(in: folded) {
            plan.filters.dateRange = range
            plan.filterDescriptions.append(title)
            removable.append(phrase)
        }

        // People known from the notes; a word that names a label is no person.
        let words = Set(TextAnalysis.normalizedWords(in: question)).subtracting(labelWords)
        let persons = knownPersons.filter { person in
            let personWords = TextAnalysis.normalizedWords(in: person)
            // A first name alone ("Anna") is enough; very short tokens are ignored.
            return personWords.contains { $0.count >= 3 && words.contains($0) }
        }
        let personNames = Self.firstNames(of: persons, mentionedIn: words)
        if !personNames.isEmpty {
            plan.filters.persons = personNames
            plan.filterDescriptions += personNames.map { String(localized: "Person: \($0)", bundle: .module) }
        }

        // Kinds and favorites.
        var kinds = Set<NoteKind>()
        if folded.containsAny([" aufnahme", " aufzeichnung", " recording"]) { kinds.insert(.recording) }
        if folded.containsAny([" pdf", " dokument", " document"]) { kinds.insert(.document) }
        if folded.containsAny([" foto", " bild ", " bilder", " photo", " image"]) { kinds.insert(.image) }
        if folded.containsAny([" audiodatei", " audio datei", " audio file"]) { kinds.insert(.audioImport) }
        if !kinds.isEmpty {
            plan.filters.kinds = kinds
            plan.filterDescriptions.append(kinds.map(\.displayName).sorted().joined(separator: ", "))
        }
        if folded.containsAny([" favorit", " favourite", " favorite"]) {
            plan.filters.favoritesOnly = true
            plan.filterDescriptions.append(String(localized: "Favoriten", bundle: .module))
        }

        // Focus (a soft preference).
        let focusWords: [(RecordingFocus, [String])] = [
            (.meeting, [" meeting", " besprechung", " sitzung", " call "]),
            (.lecture, [" vorlesung", " lecture", " seminar", " unterricht"]),
            (.interview, [" interview"]),
            (.sales, [" kundengesprach", " kunde", " sales", " verkauf"]),
            (.oneOnOne, [" 1 1 ", " one on one", " mitarbeitergesprach"]),
        ]
        plan.filters.preferredFocus = focusWords.first { folded.containsAny($0.1) }?.0

        // Listing requests.
        plan.wantsList = folded.containsAny([" zeig", " liste", " welche notizen", " welche aufnahmen", " alle ", " show ", " list "])
            && !folded.containsAny([" was ", " wie ", " warum ", " what ", " how ", " why "])
        plan.wantsCollectionSummary = Self.asksForCollectionSummary(folded)
        if plan.wantsCollectionSummary {
            removable += Self.collectionWords
        }

        plan.searchText = Self.removing(removable, from: question)
        return plan
    }

    /// The known labels the question names, as whole words, longest first ("Projekt Atlas"
    /// before "Atlas").
    static func labels(in folded: String, knownLabels: [String]) -> [String] {
        var found: [String] = []
        var remaining = folded
        for label in knownLabels.sorted(by: { $0.count > $1.count }) {
            let words = TextAnalysis.normalizedWords(in: label)
            guard !words.isEmpty else { continue }
            let phrase = " " + words.joined(separator: " ") + " "
            guard remaining.contains(phrase) else { continue }
            found.append(label)
            remaining = remaining.replacingOccurrences(of: phrase, with: " ")
        }
        return found
    }

    /// "Fasse alle Meetings mit Anna zusammen", "Zusammenfassung aller Samsung-Notizen",
    /// "Überblick über die letzten Vorlesungen".
    static func asksForCollectionSummary(_ folded: String) -> Bool {
        let summarizing = folded.containsAny([" zusammenfass", " fasse ", " fass ", " summarize ", " summarise ", " summary of ", " uberblick uber "])
        let several = folded.containsAny([
            " alle", " aller ", " samtliche", " meetings ", " notizen ", " aufnahmen ", " gesprache ", " vorlesungen ",
            " letzten ", " all ", " notes ", " recordings ",
        ])
        return summarizing && several
    }

    /// Words of a request for a summary that are no search terms: the request itself and what
    /// it is about in general ("alle Meetings"). What remains is the topic ("zum Budget").
    static let collectionWords = [
        "fasse", "fass", "zusammen", "zusammenfassung", "zusammenfassen", "aller", "alle", "sämtliche", "überblick über",
        "summarize", "summarise", "summary of", "all",
        "meetings", "meeting", "notizen", "notiz", "aufnahmen", "aufnahme", "gespräche", "gespräch", "besprechungen",
        "besprechung", "vorlesungen", "vorlesung", "termine", "calls", "notes", "recordings",
    ]

    /// For "Anna" in the question and "Anna Schmidt" in the notes, the filter uses what the
    /// user wrote, which matches both.
    private static func firstNames(of persons: [String], mentionedIn words: Set<String>) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for person in persons {
            let mentioned = TextAnalysis.normalizedWords(in: person).filter { words.contains($0) && $0.count >= 3 }
            let name = person.split(separator: " ").filter { mentioned.contains(TextAnalysis.fold(String($0))) }.joined(separator: " ")
            let value = name.isEmpty ? person : name
            if seen.insert(TextAnalysis.key(value)).inserted {
                result.append(value)
            }
        }
        return result
    }

    // MARK: Dates

    private func dateRange(in folded: String) -> (DateInterval, String, String)? {
        let phrases: [(Timeframe, [String])] = [
            (.today, [" heute", " today"]),
            (.yesterday, [" gestern", " yesterday"]),
            (.lastWeek, [" letzte woche", " letzten woche", " vergangene woche", " vergangenen woche", " vorige woche", " vorigen woche", " last week"]),
            (.thisWeek, [" diese woche", " dieser woche", " this week"]),
            (.lastMonth, [" letzten monat", " letzter monat", " letztem monat", " vergangenen monat", " vorigen monat", " last month"]),
            (.thisMonth, [" diesen monat", " diesem monat", " dieser monat", " this month"]),
            (.lastYear, [" letztes jahr", " letzten jahr", " vergangenes jahr", " vergangenen jahr", " vorjahr", " last year"]),
            (.thisYear, [" dieses jahr", " diesem jahr", " this year"]),
        ]
        if folded.contains(" vorgestern"), let day = calendar.date(byAdding: .day, value: -2, to: now),
           let range = calendar.dateInterval(of: .day, for: day) {
            return (range, String(localized: "Vorgestern", bundle: .module), "vorgestern")
        }
        for (timeframe, words) in phrases {
            if let phrase = words.first(where: folded.contains), let range = timeframe.dateRange(now: now, calendar: calendar) {
                return (range, timeframe.title, phrase.trimmingCharacters(in: .whitespaces))
            }
        }
        if let match = folded.firstMatch(of: /(?:letzten|vergangenen|last|past) (\d{1,3}) (?:tagen|tage|days)/),
           let days = Int(match.1), let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) {
            return (DateInterval(start: start, end: now), String(localized: "Letzte \(days) Tage", bundle: .module), String(match.0))
        }
        if let (range, name, phrase) = monthRange(in: folded) {
            return (range, name, phrase)
        }
        return nil
    }

    /// "im März" → the most recent March (this year if it has begun, otherwise last year).
    private func monthRange(in folded: String) -> (DateInterval, String, String)? {
        let months = [
            ["januar", "january", "jan"], ["februar", "february", "feb"], ["marz", "march"], ["april", "apr"],
            // "may" is left out: in English questions it is almost always the verb.
            ["mai"], ["juni", "june"], ["juli", "july"], ["august", "aug"],
            ["september", "sept"], ["oktober", "october", "okt"], ["november", "nov"], ["dezember", "december", "dez"],
        ]
        for (index, names) in months.enumerated() {
            guard let name = names.first(where: { folded.contains(" \($0) ") }) else { continue }
            let currentYear = calendar.component(.year, from: now)
            let currentMonth = calendar.component(.month, from: now)
            let year = index + 1 <= currentMonth ? currentYear : currentYear - 1
            guard let start = calendar.date(from: DateComponents(year: year, month: index + 1, day: 1)),
                  let range = calendar.dateInterval(of: .month, for: start) else { continue }
            let title = start.formatted(.dateTime.month(.wide).year())
            return (range, title, name)
        }
        return nil
    }

    /// The question without the phrases, as whole words; a colon or dash after a removed
    /// label ("Samsung: …") goes with it.
    ///
    /// Phrases come from the accent-free question ("marz" removes "März"), so they are matched
    /// in a folded copy. Folding keeps the length of precomposed letters, so the positions found
    /// there are valid in the question; otherwise plain replacement is used.
    static func removing(_ phrases: [String], from question: String) -> String {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var text = question
        for phrase in phrases where !phrase.isEmpty {
            let folded = text.folding(options: options, locale: nil)
            let words = phrase.folding(options: options, locale: nil)
                .split(whereSeparator: \.isWhitespace)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = #"(?<![\p{L}\p{N}])"# + words.joined(separator: #"\s+"#) + #"(?![\p{L}\p{N}])[:\-–]?"#
            guard folded.utf16.count == text.utf16.count, !words.isEmpty,
                  let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else {
                text = text.replacingOccurrences(of: phrase, with: " ", options: options)
                continue
            }
            let mutable = NSMutableString(string: text)
            for match in expression.matches(in: folded, range: NSRange(location: 0, length: folded.utf16.count)).reversed() {
                mutable.replaceCharacters(in: match.range, with: " ")
            }
            text = mutable as String
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private extension String {
    func containsAny(_ needles: [String]) -> Bool {
        needles.contains { contains($0) }
    }
}
