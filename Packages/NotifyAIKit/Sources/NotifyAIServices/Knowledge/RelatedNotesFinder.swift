//
//  RelatedNotesFinder.swift
//  NotifyAIServices
//

import Foundation

/// Why two notes are related.
public enum RelationReason: Hashable, Sendable {
    case person(String)
    case place(String)
    case organization(String)
    case topic(String)
    case similarContent
    case sameWeek

    public var title: String {
        switch self {
        case .person(let name): name
        case .place(let name): name
        case .organization(let name): name
        case .topic(let topic): topic
        case .similarContent: String(localized: "Ähnlicher Inhalt", bundle: .module)
        case .sameWeek: String(localized: "Gleiche Woche", bundle: .module)
        }
    }

    public var symbolName: String {
        switch self {
        case .person: "person"
        case .place: "mappin.and.ellipse"
        case .organization: "building.2"
        case .topic: "tag"
        case .similarContent: "text.magnifyingglass"
        case .sameWeek: "calendar"
        }
    }
}

public struct RelatedNote: Identifiable, Sendable {
    public let note: IndexedNote
    /// 0…1.
    let score: Double
    public let reasons: [RelationReason]
    public var id: UUID { note.id }
}

/// Connects notes that belong together: the same topic, the same people, places or
/// organizations, similar content, close in time.
///
/// Every signal is scored between 0 and 1 and weighted. Shared keywords are weighted by
/// how rare they are across all notes (inverse document frequency): two notes sharing
/// "Website-Relaunch" are related, two notes sharing "Projekt" are not.
struct RelatedNotesFinder: Sendable {
    struct Weights: Sendable {
        var content = 0.40
        var persons = 0.25
        var placesAndOrganizations = 0.10
        var topics = 0.20
        var time = 0.05
    }

    let index: KnowledgeIndex
    var weights = Weights()
    /// Minimum score for a note to be shown as related.
    var threshold = 0.22
    /// How many standard deviations above the average similarity content counts fully.
    ///
    /// Apple's German sentence embeddings share a common direction: averaged note vectors of
    /// a marketing meeting and a statistics lecture measured 0.60. Absolute similarities
    /// therefore mean little; what matters is how much more similar a note is than the
    /// others. This needs a few notes to compare with (`minimumNotesForContent`).
    var contentDeviations = 2.0
    var minimumNotesForContent = 4

    func related(to noteID: UUID, limit: Int = 5) -> [RelatedNote] {
        guard let source = index.notes[noteID] else { return [] }
        let keywordIDF = keywordRarity()
        let sourceKeywords = keywordKeys(of: source)
        let contentScores = relativeContentScores(for: source)

        return index.notes.values
            .filter { $0.id != noteID }
            .compactMap { candidate -> RelatedNote? in
                var reasons: [RelationReason] = []
                var score = 0.0

                // Content: clearly more similar than the other notes (same language only).
                if let contentScore = contentScores[candidate.id] {
                    score += weights.content * contentScore
                    if contentScore >= 0.75 { reasons.append(.similarContent) }
                }

                // People.
                let persons = shared(source.persons, candidate.persons)
                if !persons.isEmpty {
                    score += weights.persons * min(1, Double(persons.count) * 0.6)
                    reasons += persons.prefix(2).map(RelationReason.person)
                }

                // Places and organizations.
                let places = shared(source.entities.places, candidate.entities.places)
                let organizations = shared(source.entities.organizations, candidate.entities.organizations)
                if !places.isEmpty || !organizations.isEmpty {
                    score += weights.placesAndOrganizations * min(1, Double(places.count + organizations.count) * 0.6)
                    reasons += organizations.prefix(1).map(RelationReason.organization)
                    reasons += places.prefix(1).map(RelationReason.place)
                }

                // Topics and keywords, weighted by rarity.
                let candidateKeywords = keywordKeys(of: candidate)
                let sharedKeywords = sourceKeywords.keys.filter { candidateKeywords[$0] != nil }
                if !sharedKeywords.isEmpty {
                    let rarity = sharedKeywords.reduce(0.0) { $0 + (keywordIDF[$1] ?? 0) }
                    score += weights.topics * min(1, rarity / 2)
                    let strongest = sharedKeywords.sorted { (keywordIDF[$0] ?? 0) > (keywordIDF[$1] ?? 0) }
                    reasons += strongest.prefix(2).compactMap { sourceKeywords[$0] }.map(RelationReason.topic)
                }

                // Time.
                if abs(source.createdAt.timeIntervalSince(candidate.createdAt)) <= 7 * 24 * 3_600 {
                    score += weights.time
                    if !reasons.isEmpty { reasons.append(.sameWeek) }
                }

                guard score >= threshold, reasons.contains(where: { $0 != .sameWeek }) else { return nil }
                return RelatedNote(note: candidate, score: min(1, score), reasons: reasons)
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.note.createdAt > $1.note.createdAt }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Helpers

    /// 0…1 per candidate: how far its similarity lies above the average, in standard deviations.
    private func relativeContentScores(for source: IndexedNote) -> [UUID: Double] {
        guard let sourceVector = source.vector else { return [:] }
        let similarities: [(UUID, Double)] = index.notes.values.compactMap { candidate in
            guard candidate.id != source.id, candidate.languageCode == source.languageCode, let vector = candidate.vector else { return nil }
            return (candidate.id, Double(sourceVector.similarity(to: vector)))
        }
        guard similarities.count >= minimumNotesForContent else { return [:] }
        let values = similarities.map(\.1)
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let deviation = variance.squareRoot()
        guard deviation > 1e-6 else { return [:] }
        return Dictionary(uniqueKeysWithValues: similarities.map { id, similarity in
            (id, min(1, max(0, (similarity - mean) / (contentDeviations * deviation))))
        })
    }

    /// Names present in both lists, matched loosely ("Anna" ↔ "Anna Schmidt").
    private func shared(_ lhs: [String], _ rhs: [String]) -> [String] {
        lhs.filter { name in
            !TextAnalysis.isSpeakerLabel(name) && rhs.contains { HybridRetriever.name($0, matches: name) }
        }
    }

    /// Normalized keyword → display form.
    private func keywordKeys(of note: IndexedNote) -> [String: String] {
        var keys: [String: String] = [:]
        for keyword in note.keywords + note.topics {
            let key = TextAnalysis.terms(in: keyword, languageCode: note.languageCode).joined(separator: " ")
            if !key.isEmpty, keys[key] == nil {
                keys[key] = keyword
            }
        }
        return keys
    }

    /// Inverse document frequency of every keyword, scaled so a keyword that appears in only
    /// two notes scores about 1 and one that appears everywhere about 0.
    private func keywordRarity() -> [String: Double] {
        var documentFrequency: [String: Int] = [:]
        for note in index.notes.values {
            for key in keywordKeys(of: note).keys {
                documentFrequency[key, default: 0] += 1
            }
        }
        let count = Double(max(index.notes.count, 2))
        let maximum = log(count / 2) + 1
        return documentFrequency.mapValues { df in
            max(0, (log(count / Double(df)) + 1) / maximum)
        }
    }
}
