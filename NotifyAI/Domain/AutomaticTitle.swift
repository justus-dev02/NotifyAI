//
//  AutomaticTitle.swift
//  NotifyAI
//

import Foundation
import NotifyAICore

/// Titles for recordings without a user-defined title: one to three keywords from the
/// conversation plus the recording date, e.g. "Budget, Website-Relaunch – 29. Sept. 2026".
enum AutomaticTitle {
    static let maximumKeywords = 3
    /// Longer keyword parts are shortened so the title stays readable in lists.
    static let maximumKeywordLength = 48

    static func make(keywords: [String], date: Date, locale: Locale = .current) -> String {
        let datePart = date.formatted(Date.FormatStyle(locale: locale).day().month(.abbreviated).year())
        var seen = Set<String>()
        var parts: [String] = []
        var length = 0
        for keyword in keywords {
            let cleaned = keyword
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            guard !cleaned.isEmpty, seen.insert(TextAnalysis.key(cleaned)).inserted else { continue }
            let capitalized = cleaned.prefix(1).uppercased() + cleaned.dropFirst()
            // The first keyword is always kept; further ones only while the title stays short.
            if !parts.isEmpty, length + capitalized.count + 2 > maximumKeywordLength { break }
            parts.append(capitalized)
            length += capitalized.count + 2
            if parts.count == maximumKeywords { break }
        }
        guard !parts.isEmpty else {
            return "\(NoteKind.recording.displayName) – \(datePart)"
        }
        return "\(parts.joined(separator: ", ")) – \(datePart)"
    }

    /// Keywords for the title, best source first: the summary's keywords, its topics, and
    /// finally the nouns and names of the transcript itself.
    static func keywords(summary: NoteSummary?, transcriptText: String, languageCode: String) -> [String] {
        if let keywords = summary?.keywords, !keywords.isEmpty {
            return keywords
        }
        if let topics = summary?.topics.map(\.title), !topics.isEmpty {
            return Array(topics.prefix(2))
        }
        return TextAnalysis.keywords(in: transcriptText, languageCode: languageCode, limit: 2)
    }
}
