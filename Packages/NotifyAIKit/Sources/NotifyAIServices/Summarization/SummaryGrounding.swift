//
//  SummaryGrounding.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore

/// Keeps only the tasks, decisions and open questions the text supports, and removes the
/// placeholders a language model writes instead of leaving a field empty.
///
/// A small on-device model tends to fill every list: it turns topics into tasks ("Umsetzung
/// der nächsten Schritte"), invents decisions and writes "nicht angegeben" as the owner. An
/// item is kept only if it shares at least one content word with the text (names, nouns,
/// verbs; stop words do not count). That is a low bar for anything actually said and still
/// removes items made up from nothing. It runs after every summarizer, so the extractive
/// fallback and chapter summaries follow the same rule.
struct SummaryGrounding: Sendable {
    /// What models write when nobody or nothing was named, normalized.
    static let placeholders: Set<String> = [
        "nicht angegeben", "keine angabe", "keine angaben", "keine", "keiner", "kein", "niemand", "unbekannt",
        "unklar", "offen", "ohne", "ka", "na", "none", "nobody", "unknown", "not specified", "unspecified",
        "not mentioned", "nicht genannt", "nicht erwähnt", "tbd", "tba",
    ]

    let textTerms: Set<String>
    let languageCode: String

    init(text: String, languageCode: String) {
        self.languageCode = languageCode
        textTerms = Set(TextAnalysis.terms(in: text, languageCode: languageCode))
    }

    func apply(to summary: NoteSummary) -> NoteSummary {
        var grounded = summary
        grounded.decisions = summary.decisions.filter(isSupported)
        grounded.openQuestions = summary.openQuestions.filter(isSupported)
        grounded.actionItems = summary.actionItems
            .filter { isSupported($0.task) }
            .map { item in
                var cleaned = item
                cleaned.owner = Self.cleaned(item.owner)
                cleaned.due = Self.cleaned(item.due)
                return cleaned
            }
        return grounded
    }

    /// Whether the statement shares a content word with the text.
    func isSupported(_ statement: String) -> Bool {
        let terms = TextAnalysis.terms(in: statement, languageCode: languageCode)
        return terms.contains { textTerms.contains($0) }
    }

    /// `nil` for empty fields and placeholders such as "nicht angegeben".
    static func cleaned(_ field: String?) -> String? {
        guard let field else { return nil }
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.lowercased()
            .unicodeScalars.filter { CharacterSet.letters.contains($0) || $0 == " " }
            .map(String.init).joined()
        return placeholders.contains(normalized) ? nil : trimmed
    }
}
