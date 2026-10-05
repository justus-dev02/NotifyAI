//
//  TextAnalysis.swift
//  NotifyAIServices
//

import Foundation
import NaturalLanguage

/// People, places and organizations mentioned in a text.
struct NamedEntities: Codable, Hashable, Sendable {
    var persons: [String] = []
    var places: [String] = []
    var organizations: [String] = []

    var isEmpty: Bool { persons.isEmpty && places.isEmpty && organizations.isEmpty }
}

/// Language processing shared by search, related notes and automatic titles.
///
/// Everything runs on the device with Apple's `NaturalLanguage` framework: tokenization,
/// part-of-speech tagging (for keywords) and named entity recognition (people, places,
/// organizations). No model has to be downloaded or trained.
enum TextAnalysis {
    // MARK: Search terms

    /// Terms for full-text search: lowercased, accents folded, stop words removed and common
    /// suffixes stripped, so "Budgets", "Budget" and "budget" match.
    static func terms(in text: String, languageCode: String) -> [String] {
        let stopWords = SearchStopWords.words(for: languageCode)
        return normalizedWords(in: text).compactMap { word in
            guard word.count >= 2, !stopWords.contains(word) else { return nil }
            return stem(word)
        }
    }

    /// Lowercased, accent-free words.
    static func normalizedWords(in text: String) -> [String] {
        fold(text)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// Lowercased and accent-free, used to compare names and keywords.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Canonical form of a name or keyword for comparisons ("Dr. Müller" → "dr muller").
    static func key(_ text: String) -> String {
        normalizedWords(in: text).joined(separator: " ")
    }

    /// A light suffix stripper for German, English and Romance languages. It is not a real
    /// stemmer, but it is applied identically to notes and queries, which is all search needs.
    static func stem(_ word: String) -> String {
        guard word.count > 5, word.allSatisfy(\.isLetter) else { return word }
        for suffix in ["ungen", "ungs", "ern", "en", "er", "es", "e", "s", "n"] where word.hasSuffix(suffix) {
            let stem = String(word.dropLast(suffix.count))
            if stem.count >= 4 {
                return stem
            }
        }
        return word
    }

    // MARK: Keywords

    /// The nouns and names that characterise a text, most significant first.
    ///
    /// Frequency matters, but words that appear in many sentences only in passing count less
    /// than words that recur throughout the conversation. Named organizations and places get
    /// a bonus: "Website-Relaunch" or "Siemens" describe a conversation better than "Woche".
    static func keywords(in text: String, languageCode: String, limit: Int) -> [String] {
        guard !text.isEmpty, limit > 0 else { return [] }
        let stopWords = SearchStopWords.words(for: languageCode)
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]

        var counts: [String: Double] = [:]
        var display: [String: String] = [:]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: options) { tag, range in
            guard tag == .noun || tag == .otherWord else { return true }
            let word = String(text[range]).trimmingCharacters(in: .punctuationCharacters)
            let folded = fold(word)
            guard word.count >= 4, !stopWords.contains(folded), !genericNouns.contains(folded), !isSpeakerLabel(word) else { return true }
            counts[folded, default: 0] += 1
            if display[folded] == nil || word.first?.isUppercase == true {
                display[folded] = word
            }
            return true
        }
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, range in
            guard tag == .organizationName || tag == .placeName else { return true }
            let name = String(text[range])
            let folded = fold(name)
            guard name.count >= 3 else { return true }
            counts[folded, default: 0] += 1.5
            display[folded] = name
            return true
        }

        return counts
            .filter { $0.value >= 2 || counts.count < 6 }
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
            }
            .prefix(limit)
            .compactMap { display[$0.key] }
    }

    // MARK: Named entities

    /// People, places and organizations, most frequently mentioned first.
    static func entities(in text: String, limit: Int = 12) -> NamedEntities {
        guard !text.isEmpty else { return NamedEntities() }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var counts: [NLTag: [String: Int]] = [:]
        var display: [String: String] = [:]
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            guard let tag, tag == .personalName || tag == .placeName || tag == .organizationName else { return true }
            let name = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard name.count >= 2, !isSpeakerLabel(name) else { return true }
            let key = key(name)
            counts[tag, default: [:]][key, default: 0] += 1
            display[key] = display[key] ?? name
            return true
        }

        func ranked(_ tag: NLTag) -> [String] {
            (counts[tag] ?? [:])
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(limit)
                .compactMap { display[$0.key] }
        }
        return NamedEntities(persons: ranked(.personalName), places: ranked(.placeName), organizations: ranked(.organizationName))
    }

    /// Labels added by speaker attribution ("Ich", "Andere", "Sprecher 2") are not names.
    static func isSpeakerLabel(_ text: String) -> Bool {
        // Labels are written in the language of the app at the time of the recording.
        let folded = fold(text)
        let localizedLabels = [SourceSpeakerAttribution.userLabel, SourceSpeakerAttribution.defaultOthersLabel].map(fold)
        let speakerPrefix = fold(SpeakerDiarizer.speakerLabel(1)).split(separator: " ").first.map(String.init) ?? "sprecher"
        return ["ich", "andere", "me", "others"].contains(folded) || localizedLabels.contains(folded)
            || folded.hasPrefix("sprecher") || folded.hasPrefix("speaker") || folded.hasPrefix(speakerPrefix)
    }

    /// Nouns that occur in almost every conversation and say nothing about its subject.
    private static let genericNouns: Set<String> = [
        "sache", "sachen", "ding", "dinge", "zeit", "leute", "frage", "fragen", "punkt", "punkte", "moment",
        "beispiel", "problem", "thema", "themen", "teil", "seite", "woche", "tag", "tage", "jahr", "jahre",
        "minute", "minuten", "stunde", "stunden", "art", "weise", "fall", "idee", "grund", "prozent",
        "thing", "things", "time", "people", "question", "point", "example", "part", "week", "year", "minute", "way",
    ]
}

/// Words without meaning for search. Stored folded (lowercase, no accents), like the words they filter.
enum SearchStopWords {
    static func words(for languageCode: String) -> Set<String> {
        // Transcripts mix in filler words; the common list is applied to every language.
        common.union(byLanguage[languageCode] ?? [])
    }

    private static let common: Set<String> = [
        "ok", "okay", "ja", "ah", "ahm", "hm", "hmm", "mhm", "uh", "um", "yeah", "yes", "no",
    ]

    private static let byLanguage: [String: Set<String>] = [
        "de": [
            "und", "oder", "aber", "der", "die", "das", "den", "dem", "des", "ein", "eine", "einer", "einem", "einen", "eines",
            "ist", "sind", "war", "waren", "bin", "bist", "hat", "habe", "haben", "hatte", "hatten", "wir", "ihr", "sie", "ich",
            "du", "er", "es", "mich", "mir", "dich", "dir", "uns", "euch", "ihm", "ihn", "ihnen", "nicht", "auch", "mit", "fur",
            "auf", "von", "zu", "zum", "zur", "im", "in", "an", "am", "als", "wie", "dass", "noch", "schon", "dann", "also", "mal",
            "nein", "so", "was", "wer", "wo", "wann", "warum", "wenn", "man", "nach", "bei", "aus", "um", "uber", "sich", "sein",
            "wird", "werden", "wurde", "wurden", "kann", "konnen", "muss", "mussen", "soll", "sollen", "will", "wollen", "hier",
            "da", "jetzt", "eben", "halt", "genau", "gut", "sehr", "mehr", "nur", "doch", "ganz", "gibt", "gab", "machen", "macht",
            "diese", "dieser", "dieses", "diesem", "diesen", "welche", "welcher", "alle", "alles", "etwas", "nichts", "viel",
            "vielleicht", "einfach", "irgendwie", "quasi", "sozusagen", "gesagt", "sagen", "sagt", "bitte", "danke", "vom",
        ],
        "en": [
            "the", "and", "or", "but", "a", "an", "is", "are", "was", "were", "be", "been", "has", "have", "had", "we", "you",
            "they", "i", "he", "she", "it", "me", "him", "her", "us", "them", "my", "our", "your", "not", "also", "with", "for",
            "on", "of", "to", "in", "at", "as", "that", "this", "these", "those", "then", "so", "what", "who", "where", "when",
            "why", "if", "by", "from", "about", "just", "like", "will", "would", "can", "could", "should", "do", "does", "did",
            "there", "here", "now", "very", "more", "only", "all", "some", "any", "really", "actually", "basically", "said", "say",
        ],
        "fr": [
            "le", "la", "les", "un", "une", "des", "et", "ou", "mais", "est", "sont", "de", "du", "a", "au", "en", "je", "tu", "il", "elle",
            "nous", "vous", "ils", "que", "qui", "pour", "pas", "ne", "avec", "sur", "dans", "ce", "cette"
        ],
        "es": [
            "el", "la", "los", "las", "un", "una", "y", "o", "pero", "es", "son", "de", "del", "a", "en", "yo", "tu", "el", "ella", "nosotros",
            "que", "para", "no", "con", "por", "este", "esta"
        ],
        "it": [
            "il", "lo", "la", "i", "gli", "le", "un", "una", "e", "o", "ma", "e", "sono", "di", "da", "a", "in", "io", "tu", "lui", "lei", "noi",
            "che", "per", "non", "con", "su", "questo", "questa"
        ],
    ]
}
