//
//  HybridRetriever.swift
//  NotifyAIKnowledge
//

import Foundation
import NotifyAICore
import NotifyAISupport

/// Restrictions a question implies, e.g. "letzte Woche" or "mit Anna".
struct SearchFilters: Equatable, Sendable {
    var dateRange: DateInterval?
    /// Notes must carry one of these labels.
    var labels: [String] = []
    /// Notes must mention or involve one of these people.
    var persons: [String] = []
    var kinds: Set<NoteKind>?
    var favoritesOnly = false
    /// Not a hard filter: many meetings are recorded with the default focus.
    var preferredFocus: RecordingFocus?

    var isEmpty: Bool {
        dateRange == nil && labels.isEmpty && persons.isEmpty && kinds == nil && !favoritesOnly && preferredFocus == nil
    }
}

struct SearchRequest: Sendable {
    /// The content to look for.
    var text: String
    /// Extra terms such as synonyms from query expansion. They count less than the question itself.
    var expansions: [String] = []
    var filters = SearchFilters()
    var languageCode: String
}

/// A passage that matches a request.
struct PassageHit: Identifiable, Sendable {
    let passage: IndexedPassage
    let note: IndexedNote
    let score: Double
    var id: String { passage.id }
}

/// A note that matches a request, with the reasons shown to the user.
struct NoteHit: Identifiable, Sendable {
    let note: IndexedNote
    let score: Double
    let reasons: [String]
    var id: UUID { note.id }
}

struct SearchResult: Sendable {
    var passages: [PassageHit] = []
    var notes: [NoteHit] = []
    /// Set when a person filter matched no note and was dropped to still find something.
    var relaxedPersons: [String] = []
    /// Set when a label filter matched no note and was dropped to still find something.
    var relaxedLabels: [String] = []
    /// Notes left after applying the filters.
    var candidateCount = 0
}

/// Finds the passages and notes that answer a request.
///
/// Every passage gets one score from two signals:
/// - **Coverage:** the share of the question's terms the passage contains, each weighted by
///   how rare it is among the candidate passages (inverse document frequency). It finds exact
///   names, numbers and technical terms, which meaning vectors blur.
/// - **Meaning:** the similarity of the passage's best 25-word window to the question
///   (`ContextualSentenceEmbedder`), which finds the same thing said in other words.
///
/// `score = 0.7 · similarity + 0.3 · coverage`, and a passage answers the question from a
/// score of 0.32. Both values were chosen on `SearchEvaluationCorpus.json` and checked by
/// cross-validation (docs/Quality.md): compared with the previous rank fusion, questions with
/// the note's own words find it first in 96 % instead of 72 % of cases, questions in other
/// words in 46 % instead of 29 %, and a question no note answers names a note in 12 % instead
/// of 50 % of cases. The threshold is what makes the answer "nothing found" possible.
///
/// Only vectors of the contextual model are calibrated for this. Passages without them (the
/// model is not installed, or the language has none) are scored by coverage alone, from 0.22:
/// measured, the older sentence embeddings made rankings worse, not better.
///
/// Filters are applied first; mentioned people and the preferred focus raise the score of a
/// passage that already answers.
package struct HybridRetriever: Sendable {
    /// How full text and meaning are weighed; tests evaluate other values.
    struct Tuning: Sendable {
        var semanticWeight = 0.7
        /// Score from which a passage with a meaning vector answers the question.
        var threshold = 0.32
        /// Coverage from which a passage without a meaning vector answers the question.
        var fullTextThreshold = 0.22
        /// Synonyms from the query expansion count less than the question's own words.
        var expansionWeight = 0.4
    }

    let index: KnowledgeIndex
    let embedder: any SentenceEmbedding
    var tuning = Tuning()

    private let k1 = 1.2
    private let b = 0.75
    private let maximumPassagesPerNote = 3

    func search(_ request: SearchRequest, passageLimit: Int = 12, noteLimit: Int = 10) -> SearchResult {
        var request = request
        var result = SearchResult()
        let candidates = candidates(for: request.filters, result: &result)
        if !result.relaxedLabels.isEmpty {
            // The label was meant as a filter; without its notes it becomes a search term again.
            request.text = ([request.text] + result.relaxedLabels).joined(separator: " ")
        }
        return search(request, candidates: candidates, result: result, passageLimit: passageLimit, noteLimit: noteLimit)
    }

    private func search(
        _ request: SearchRequest,
        candidates: [IndexedNote],
        result: SearchResult,
        passageLimit: Int,
        noteLimit: Int
    ) -> SearchResult {
        var result = result
        result.candidateCount = candidates.count
        guard !candidates.isEmpty else { return result }

        let passages = candidates.flatMap { note in note.passages.map { (note, $0) } }
        let queryTerms = TextAnalysis.terms(in: request.text, languageCode: request.languageCode)
        let expansionTerms = request.expansions.flatMap { TextAnalysis.terms(in: $0, languageCode: request.languageCode) }

        // A request that only consists of filters ("Alle Meetings letzte Woche") lists the notes.
        guard !queryTerms.isEmpty || !expansionTerms.isEmpty else {
            return listing(candidates, result: result, filters: request.filters, noteLimit: noteLimit)
        }

        // 1. Full text: coverage of the question's terms, BM25 to break ties.
        let lexical = lexicalScores(queryTerms: queryTerms, expansionTerms: expansionTerms, notes: candidates, passageCount: passages.count)
        // 2. Meaning: the best window of each passage.
        let semantic = semanticScores(of: candidates, passageCount: passages.count, for: request)
        // 3. One score per passage; only passages that answer remain.
        let scored = answeringPassages(passages: passages, lexical: lexical, semantic: semantic, request: request,
                                       personsRelaxed: !result.relaxedPersons.isEmpty)
        // 4. Diverse passages: at most a few per note, so one long meeting does not crowd out the rest.
        result.passages = diversePassages(scored, passages: passages, limit: passageLimit)
        // 5. Notes ranked by their best passage.
        result.notes = rankedNotes(scored, passages: passages, request: request, limit: noteLimit)
        return result
    }

    // MARK: - Steps

    /// The notes the filters allow. A label or person filter that matches no note is dropped
    /// and reported in `result.relaxedLabels` / `relaxedPersons`, so the search still finds
    /// something.
    private func candidates(for filters: SearchFilters, result: inout SearchResult) -> [IndexedNote] {
        var candidates = index.notes.values.filter { matches($0, filters, includePersons: false) }
        if !filters.labels.isEmpty {
            let keys = Set(filters.labels.map(NoteLabel.key))
            let labeled = candidates.filter { note in note.labels.contains { keys.contains(NoteLabel.key($0)) } }
            if labeled.isEmpty {
                result.relaxedLabels = filters.labels
            } else {
                candidates = labeled
            }
        }
        guard !filters.persons.isEmpty else { return Array(candidates) }
        let withPersons = candidates.filter { mentions($0, anyOf: filters.persons) }
        if withPersons.isEmpty {
            result.relaxedPersons = filters.persons
            return Array(candidates)
        }
        return withPersons
    }

    /// The best window similarity of every passage, -1 for passages without calibrated
    /// vectors, in the order of `passages` in `search` (note by note).
    ///
    /// The question is embedded once per vector space. Notes are compared only with a
    /// question vector of their own space; one space can hold several languages.
    func semanticScores(of notes: [IndexedNote], passageCount: Int, for request: SearchRequest) -> [Double] {
        let semanticText = ([request.text] + request.expansions).joined(separator: " ")
        var queryVectors: [String: [Float]?] = [:]
        func queryVector(in space: String, noteLanguage: String) -> [Float]? {
            if let known = queryVectors[space] { return known }
            // The question's language first: in a shared space it is the more faithful vector.
            let language = [request.languageCode, noteLanguage].first { embedder.space(for: $0) == space }
            let vector = language.flatMap { embedder.vector(for: semanticText, languageCode: $0)?.values }
            queryVectors[space] = vector
            return vector
        }

        var semantic: [Double] = []
        semantic.reserveCapacity(passageCount)
        var scratch: [Float] = []
        for note in notes {
            guard let space = note.embeddingSpace, ContextualSentenceEmbedder.isCalibrated(space: space),
                  let query = queryVector(in: space, noteLanguage: note.languageCode)
            else {
                semantic += repeatElement(-1, count: note.passages.count)
                continue
            }
            let scores = note.passageVectors.bestScores(for: query, passageCount: note.passages.count, scratch: &scratch)
            semantic += scores.map(Double.init)
        }
        return semantic
    }

    /// The passages that answer the question, best first, with their score. Boosts for
    /// mentioned people and the preferred focus only reorder passages that already answer.
    private func answeringPassages(
        passages: [(IndexedNote, IndexedPassage)],
        lexical: [(coverage: Double, bm25: Double)],
        semantic: [Double],
        request: SearchRequest,
        personsRelaxed: Bool
    ) -> [(position: Int, score: Double)] {
        var scored: [(position: Int, score: Double, bm25: Double)] = []
        for position in passages.indices {
            let coverage = lexical[position].coverage
            var score: Double
            if semantic[position] > -1 {
                score = tuning.semanticWeight * max(0, semantic[position]) + (1 - tuning.semanticWeight) * coverage
                guard score >= tuning.threshold else { continue }
            } else {
                score = coverage
                guard score > 0, score >= tuning.fullTextThreshold else { continue }
            }
            let (note, passage) = passages[position]
            if !request.filters.persons.isEmpty, !personsRelaxed,
               request.filters.persons.contains(where: { Self.text(passage.text, mentions: $0) }) {
                score *= 1.25
            }
            if let focus = request.filters.preferredFocus, note.focus == focus {
                score *= 1.1
            }
            scored.append((position, score, lexical[position].bm25))
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.bm25 > $1.bm25 }
            .map { ($0.position, $0.score) }
    }

    private func diversePassages(
        _ scored: [(position: Int, score: Double)],
        passages: [(IndexedNote, IndexedPassage)],
        limit: Int
    ) -> [PassageHit] {
        var hits: [PassageHit] = []
        var perNote: [UUID: Int] = [:]
        for entry in scored {
            let (note, passage) = passages[entry.position]
            guard perNote[note.id, default: 0] < maximumPassagesPerNote else { continue }
            perNote[note.id, default: 0] += 1
            hits.append(PassageHit(passage: passage, note: note, score: entry.score))
            if hits.count >= limit { break }
        }
        return hits
    }

    /// Notes ranked by their best answering passage.
    private func rankedNotes(
        _ scored: [(position: Int, score: Double)],
        passages: [(IndexedNote, IndexedPassage)],
        request: SearchRequest,
        limit: Int
    ) -> [NoteHit] {
        let matchedTerms = Set(TextAnalysis.terms(in: request.text, languageCode: request.languageCode))
        var seen = Set<UUID>()
        var hits: [NoteHit] = []
        // `scored` is sorted, so a note's first entry is its best passage.
        for entry in scored where seen.insert(passages[entry.position].0.id).inserted {
            let note = passages[entry.position].0
            hits.append(NoteHit(note: note, score: entry.score, reasons: reasons(for: note, matchedTerms: matchedTerms, filters: request.filters)))
            if hits.count >= limit { break }
        }
        return hits
    }

    // MARK: - Filters

    private func matches(_ note: IndexedNote, _ filters: SearchFilters, includePersons: Bool) -> Bool {
        if let range = filters.dateRange, !range.contains(note.createdAt) { return false }
        if let kinds = filters.kinds, !kinds.contains(note.kind) { return false }
        if filters.favoritesOnly, !note.isFavorite { return false }
        if includePersons, !filters.persons.isEmpty, !mentions(note, anyOf: filters.persons) { return false }
        return true
    }

    /// Whether a note involves one of the people: as participant, recognized name or in its text.
    func mentions(_ note: IndexedNote, anyOf persons: [String]) -> Bool {
        persons.contains { person in
            note.persons.contains { Self.name($0, matches: person) }
                || note.passages.contains { Self.text($0.text, mentions: person) }
        }
    }

    /// "Anna" matches "Anna Schmidt" and "anna"; "Schmidt" matches "Frau Schmidt".
    package static func name(_ name: String, matches query: String) -> Bool {
        let nameWords = TextAnalysis.normalizedWords(in: name)
        let queryWords = TextAnalysis.normalizedWords(in: query)
        guard !nameWords.isEmpty, !queryWords.isEmpty else { return false }
        return queryWords.allSatisfy { nameWords.contains($0) } || nameWords.allSatisfy { queryWords.contains($0) }
    }

    static func text(_ text: String, mentions person: String) -> Bool {
        let words = Set(TextAnalysis.normalizedWords(in: text))
        let personWords = TextAnalysis.normalizedWords(in: person)
        return !personWords.isEmpty && personWords.allSatisfy { words.contains($0) }
    }

    // MARK: - Ranking

    /// Coverage of the question's terms and Okapi BM25 for every passage.
    ///
    /// Coverage is the sum of the inverse document frequencies of the terms a passage contains
    /// divided by that of all the question's terms (synonyms from the expansion count with
    /// `expansionWeight`), at most 1. Unlike BM25 it is comparable between questions, so one
    /// threshold can decide what answers. BM25 only breaks ties between equal coverage.
    ///
    /// Rarity is a property of the library, not of a filter: document frequencies count all
    /// passages of the index. And it is smoothed (`log((N + 1) / (df + 1)) + 1`, at least 1):
    /// with BM25's own weights, a word of the question that no note contains outweighed all
    /// others, and "Samsung: Wie hoch ist das Budget?" found nothing, because within the two
    /// Samsung notes "Budget" was everywhere and "hoch" nowhere.
    ///
    /// Walks the notes and their passages in the order of `passages` in `search` (note by
    /// note), so the scores line up with it without copying a note for every passage.
    private func lexicalScores(
        queryTerms: [String],
        expansionTerms: [String],
        notes: [IndexedNote],
        passageCount: Int
    ) -> [(coverage: Double, bm25: Double)] {
        guard passageCount > 0 else { return [] }
        var weights: [String: Double] = [:]
        for term in queryTerms { weights[term, default: 0] = max(weights[term, default: 0], 1) }
        for term in expansionTerms where weights[term] == nil { weights[term] = tuning.expansionWeight }
        let weighted = Array(weights)

        // How often each query term occurs in each passage, 0 where it does not: one buffer
        // with a row per passage. The terms are looked up in each note's term list once.
        let termsCount = weighted.count
        var frequencies = [Int](repeating: 0, count: passageCount * termsCount)
        var lengths = [Int](repeating: 0, count: passageCount)
        var documentFrequency = [Int](repeating: 0, count: termsCount)
        var position = 0
        for note in notes {
            let ids = weighted.map { note.terms.id(of: $0.key) }
            for passage in note.passages {
                lengths[position] = passage.termCount
                for (term, id) in ids.enumerated() {
                    guard let id, let frequency = passage.termFrequencies.frequency(of: id) else { continue }
                    frequencies[position * termsCount + term] = frequency
                    documentFrequency[term] += 1
                }
                position += 1
            }
        }

        // A filter left out passages: count them too.
        var total = Double(passageCount)
        if notes.count < index.notes.count {
            total += countPassages(outside: notes, containing: weighted.map(\.key), into: &documentFrequency)
        }

        let averageLength = max(1, Double(lengths.reduce(0, +)) / Double(passageCount))
        let rarity = documentFrequency.map { df in log((total + 1) / (Double(df) + 1)) + 1 }
        let bm25Weights = documentFrequency.map { df in log(1 + (total - Double(df) + 0.5) / (Double(df) + 0.5)) }
        // The question's own terms make a full match; without any, its synonyms do.
        let ownTerms = weighted.indices.filter { weighted[$0].value >= 1 }
        let fullMatch = ownTerms.isEmpty
            ? weighted.indices.reduce(0) { $0 + weighted[$1].value * rarity[$1] }
            : ownTerms.reduce(0) { $0 + rarity[$1] }
        return (0..<passageCount).map { position in
            var matched = 0.0
            var bm25 = 0.0
            for (term, (_, weight)) in weighted.enumerated() {
                let frequency = frequencies[position * termsCount + term]
                guard frequency > 0 else { continue }
                matched += weight * rarity[term]
                let tf = Double(frequency)
                let normalization = tf + k1 * (1 - b + b * Double(lengths[position]) / averageLength)
                bm25 += weight * bm25Weights[term] * tf * (k1 + 1) / normalization
            }
            return (fullMatch > 0 ? min(1, matched / fullMatch) : 0, bm25)
        }
    }

    /// Adds the passages of the notes not in `candidates` that contain each term to
    /// `documentFrequency`; returns how many passages those notes have.
    private func countPassages(outside candidates: [IndexedNote], containing terms: [String], into documentFrequency: inout [Int]) -> Double {
        let candidateIDs = Set(candidates.map(\.id))
        var count = 0
        for note in index.notes.values where !candidateIDs.contains(note.id) {
            let ids = terms.map { note.terms.id(of: $0) }
            for passage in note.passages {
                for (term, id) in ids.enumerated() where id.flatMap(passage.termFrequencies.frequency(of:)) != nil {
                    documentFrequency[term] += 1
                }
            }
            count += note.passages.count
        }
        return Double(count)
    }

    private func listing(_ candidates: [IndexedNote], result: SearchResult, filters: SearchFilters, noteLimit: Int) -> SearchResult {
        var result = result
        let sorted = candidates.sorted { $0.createdAt > $1.createdAt }
        result.notes = sorted.prefix(noteLimit).map {
            NoteHit(note: $0, score: 0, reasons: reasons(for: $0, matchedTerms: [], filters: filters))
        }
        result.passages = sorted.prefix(8).compactMap { note in
            note.passages.first { $0.kind == .summary }.map { PassageHit(passage: $0, note: note, score: 0) }
        }
        return result
    }

    /// Why a note matched, in words the user understands.
    private func reasons(for note: IndexedNote, matchedTerms: Set<String>, filters: SearchFilters) -> [String] {
        var reasons: [String] = []
        let labelKeys = Set(filters.labels.map(NoteLabel.key))
        reasons += note.labels.filter { labelKeys.contains(NoteLabel.key($0)) }.map { String(localized: "Label: \($0)", bundle: .module) }
        for person in filters.persons {
            if let match = note.persons.first(where: { Self.name($0, matches: person) }) {
                reasons.append(String(localized: "Person: \(match)", bundle: .module))
            }
        }
        let keywordMatches = note.keywords.filter { keyword in
            TextAnalysis.terms(in: keyword, languageCode: note.languageCode).contains { matchedTerms.contains($0) }
        }
        reasons += keywordMatches.prefix(3).map { String(localized: "Thema: \($0)", bundle: .module) }
        if reasons.isEmpty, !matchedTerms.isEmpty {
            reasons.append(String(localized: "Inhaltlich passend", bundle: .module))
        }
        return reasons
    }
}
