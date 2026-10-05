//
//  HybridRetriever.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore

/// Restrictions a question implies, e.g. "letzte Woche" or "mit Anna".
struct SearchFilters: Equatable, Sendable {
    var dateRange: DateInterval?
    /// Notes must mention or involve one of these people.
    var persons: [String] = []
    var kinds: Set<NoteKind>?
    var favoritesOnly = false
    /// Not a hard filter: many meetings are recorded with the default focus.
    var preferredFocus: RecordingFocus?

    var isEmpty: Bool {
        dateRange == nil && persons.isEmpty && kinds == nil && !favoritesOnly && preferredFocus == nil
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
    /// Notes left after applying the filters.
    var candidateCount = 0
}

/// Finds the passages and notes that answer a request.
///
/// Two complementary rankings are fused:
/// - **BM25 full-text search** finds exact names, numbers and technical terms, which
///   embeddings tend to blur.
/// - **Sentence embeddings** find passages with the same meaning in other words
///   ("Kosten" ↔ "Budget", "Kündigung" ↔ "Vertrag beenden").
///
/// Reciprocal rank fusion combines both without having to calibrate their very different
/// score scales; the semantic ranking counts half (see `semanticWeight`). Filters are
/// applied first; mentioned people and the preferred focus boost the fused score.
struct HybridRetriever: Sendable {
    let index: KnowledgeIndex
    let embedder: any SentenceEmbedding

    private let k1 = 1.2
    private let b = 0.75
    /// Rank constant of reciprocal rank fusion (the value from the original paper).
    private let fusionK = 60.0
    /// Only the best semantic matches take part in the fusion; the long tail is noise.
    private let semanticDepth = 40
    private let maximumPassagesPerNote = 3
    /// Apple's sentence embeddings separate German topics only weakly (a question and its
    /// answer measured −0.02, the same question and an unrelated passage −0.04). They help to
    /// order candidates but count half as much as full-text matches; synonyms from the
    /// language model's query expansion carry most of the "same meaning, other words" recall.
    static let semanticWeight = 0.5

    func search(_ request: SearchRequest, passageLimit: Int = 12, noteLimit: Int = 10) -> SearchResult {
        var result = SearchResult()
        let candidates = candidates(for: request.filters, result: &result)
        result.candidateCount = candidates.count
        guard !candidates.isEmpty else { return result }

        let passages = candidates.flatMap { note in note.passages.map { (note, $0) } }
        let queryTerms = TextAnalysis.terms(in: request.text, languageCode: request.languageCode)
        let expansionTerms = request.expansions.flatMap { TextAnalysis.terms(in: $0, languageCode: request.languageCode) }

        // A request that only consists of filters ("Alle Meetings letzte Woche") lists the notes.
        guard !queryTerms.isEmpty || !expansionTerms.isEmpty else {
            return listing(candidates, result: result, filters: request.filters, noteLimit: noteLimit)
        }

        // 1. Full-text ranking.
        let lexical = bm25Scores(queryTerms: queryTerms, expansionTerms: expansionTerms, passages: passages.map(\.1))
        // 2. Semantic ranking.
        let semantic = semanticScores(of: passages, for: request)
        // 3. Fusion and boosts.
        let fused = fusedScores(passages: passages, lexical: ranks(of: lexical), semantic: ranks(of: semantic, depth: semanticDepth),
                                request: request, personsRelaxed: !result.relaxedPersons.isEmpty)
        // 4. Diverse passages: at most a few per note, so one long meeting does not crowd out the rest.
        result.passages = diversePassages(fused, passages: passages, limit: passageLimit)
        // 5. Notes ranked by their best passages.
        result.notes = rankedNotes(fused, passages: passages, lexical: lexical, request: request, limit: noteLimit)
        return result
    }

    // MARK: - Steps

    /// The notes the filters allow. A person filter that matches no note is dropped and
    /// reported in `result.relaxedPersons`, so the search still finds something.
    private func candidates(for filters: SearchFilters, result: inout SearchResult) -> [IndexedNote] {
        let candidates = index.notes.values.filter { matches($0, filters, includePersons: false) }
        guard !filters.persons.isEmpty else { return Array(candidates) }
        let withPersons = candidates.filter { mentions($0, anyOf: filters.persons) }
        if withPersons.isEmpty {
            result.relaxedPersons = filters.persons
            return Array(candidates)
        }
        return withPersons
    }

    /// Similarity of every passage to the question, per language (vectors of different
    /// languages are not comparable); -1 where a passage has no vector.
    private func semanticScores(of passages: [(IndexedNote, IndexedPassage)], for request: SearchRequest) -> [Double] {
        var queryVectors: [String: EmbeddingVector] = [:]
        var semantic = [Double](repeating: -1, count: passages.count)
        let semanticText = ([request.text] + request.expansions).joined(separator: " ")
        for (position, (note, passage)) in passages.enumerated() {
            guard let vector = passage.vector else { continue }
            let queryVector = queryVectors[note.languageCode] ?? embedder.vector(for: semanticText, languageCode: note.languageCode)
            guard let queryVector else { continue }
            queryVectors[note.languageCode] = queryVector
            semantic[position] = Double(vector.similarity(to: queryVector))
        }
        return semantic
    }

    /// Reciprocal rank fusion of both rankings, with boosts for mentioned people and the
    /// preferred focus; best first.
    private func fusedScores(
        passages: [(IndexedNote, IndexedPassage)],
        lexical: [Int: Int],
        semantic: [Int: Int],
        request: SearchRequest,
        personsRelaxed: Bool
    ) -> [(position: Int, score: Double)] {
        var fused: [(position: Int, score: Double)] = []
        for position in passages.indices {
            var score = 0.0
            if let rank = lexical[position] { score += 1 / (fusionK + Double(rank)) }
            if let rank = semantic[position] { score += Self.semanticWeight / (fusionK + Double(rank)) }
            guard score > 0 else { continue }
            let (note, passage) = passages[position]
            if !request.filters.persons.isEmpty, !personsRelaxed,
               request.filters.persons.contains(where: { Self.text(passage.text, mentions: $0) }) {
                score *= 1.25
            }
            if let focus = request.filters.preferredFocus, note.focus == focus {
                score *= 1.1
            }
            fused.append((position, score))
        }
        return fused.sorted { $0.score > $1.score }
    }

    private func diversePassages(
        _ fused: [(position: Int, score: Double)],
        passages: [(IndexedNote, IndexedPassage)],
        limit: Int
    ) -> [PassageHit] {
        var hits: [PassageHit] = []
        var perNote: [UUID: Int] = [:]
        for entry in fused {
            let (note, passage) = passages[entry.position]
            guard perNote[note.id, default: 0] < maximumPassagesPerNote else { continue }
            perNote[note.id, default: 0] += 1
            hits.append(PassageHit(passage: passage, note: note, score: entry.score))
            if hits.count >= limit { break }
        }
        return hits
    }

    /// Notes ranked by their best passages. Semantic similarity alone always finds
    /// *something* and is too weak to decide on its own, so a note only counts as a match
    /// with a full-text hit on the question or its synonyms.
    private func rankedNotes(
        _ fused: [(position: Int, score: Double)],
        passages: [(IndexedNote, IndexedPassage)],
        lexical: [Double],
        request: SearchRequest,
        limit: Int
    ) -> [NoteHit] {
        var noteScores: [UUID: [Double]] = [:]
        var qualifiedNotes = Set<UUID>()
        for entry in fused {
            let noteID = passages[entry.position].0.id
            noteScores[noteID, default: []].append(entry.score)
            if lexical[entry.position] > 0 {
                qualifiedNotes.insert(noteID)
            }
        }
        let matchedTerms = Set(TextAnalysis.terms(in: request.text, languageCode: request.languageCode))
        return noteScores
            .filter { qualifiedNotes.contains($0.key) }
            .compactMap { id, scores -> NoteHit? in
                guard let note = index.notes[id] else { return nil }
                let sorted = scores.sorted(by: >)
                let score = sorted[0] + 0.5 * (sorted.count > 1 ? sorted[1] : 0)
                return NoteHit(note: note, score: score, reasons: reasons(for: note, matchedTerms: matchedTerms, filters: request.filters))
            }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
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
    static func name(_ name: String, matches query: String) -> Bool {
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

    /// Okapi BM25 with inverse document frequencies over the candidate passages.
    private func bm25Scores(queryTerms: [String], expansionTerms: [String], passages: [IndexedPassage]) -> [Double] {
        guard !passages.isEmpty else { return [] }
        let averageLength = max(1, Double(passages.reduce(0) { $0 + $1.termCount }) / Double(passages.count))
        var weights: [String: Double] = [:]
        for term in queryTerms { weights[term, default: 0] = max(weights[term, default: 0], 1) }
        for term in expansionTerms where weights[term] == nil { weights[term] = 0.4 }

        var documentFrequency: [String: Int] = [:]
        for passage in passages {
            for term in weights.keys where passage.termFrequencies[term] != nil {
                documentFrequency[term, default: 0] += 1
            }
        }
        let count = Double(passages.count)
        return passages.map { passage in
            var score = 0.0
            for (term, weight) in weights {
                guard let frequency = passage.termFrequencies[term], let df = documentFrequency[term] else { continue }
                let idf = log(1 + (count - Double(df) + 0.5) / (Double(df) + 0.5))
                let tf = Double(frequency)
                let normalization = tf + k1 * (1 - b + b * Double(passage.termCount) / averageLength)
                score += weight * idf * tf * (k1 + 1) / normalization
            }
            return score
        }
    }

    /// Rank (1 = best) of every position with a positive score, limited to the best `depth`.
    private func ranks(of scores: [Double], depth: Int = .max) -> [Int: Int] {
        let ordered = scores.indices
            .filter { scores[$0] > 0 }
            .sorted { scores[$0] > scores[$1] }
            .prefix(depth)
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1, $0 + 1) })
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
