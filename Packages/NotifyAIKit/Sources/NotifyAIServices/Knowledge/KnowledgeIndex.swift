//
//  KnowledgeIndex.swift
//  NotifyAIServices
//

import CryptoKit
import Foundation
import NotifyAICore
import NotifyAIPersistence

/// A searchable piece of a note: a few transcript segments, a paragraph of a document or
/// the note's summary.
struct IndexedPassage: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case transcript
        case text
        case summary
    }

    let id: String
    let noteID: UUID
    let kind: Kind
    let text: String
    /// Position in the recording, for jumping to the passage.
    let start: TimeInterval?
    /// Search term frequencies (see `TextAnalysis.terms`).
    let termFrequencies: [String: Int]
    let termCount: Int
    let vector: EmbeddingVector?
}

/// Everything the search knows about one note.
public struct IndexedNote: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    /// Changes whenever content that is indexed changes; unchanged notes are not re-indexed.
    let contentHash: String
    public let title: String
    public let createdAt: Date
    public let kind: NoteKind
    let focus: RecordingFocus
    let languageCode: String
    let isFavorite: Bool
    let participants: [String]
    let entities: NamedEntities
    let keywords: [String]
    let topics: [String]
    /// Mean of all passage vectors: what the note is about as a whole.
    let vector: EmbeddingVector?
    let passages: [IndexedPassage]

    /// Everybody the note is about: entered participants and recognized names.
    var persons: [String] {
        var seen = Set<String>()
        return (participants + entities.persons).filter { seen.insert(TextAnalysis.key($0)).inserted }
    }
}

/// The search index over all notes. A value type: queries work on a consistent snapshot
/// off the main actor while the index service updates its copy.
public struct KnowledgeIndex: Codable, Sendable {
    /// Bump when the indexing changes, so existing indexes are rebuilt.
    /// 4: fingerprints based on `contentRevision`, vectors stored as Float16.
    static let formatVersion = 4

    var formatVersion = Self.formatVersion
    public var notes: [UUID: IndexedNote] = [:]

    public var passageCount: Int { notes.values.reduce(0) { $0 + $1.passages.count } }

    /// All distinct persons, for recognizing names in questions.
    var knownPersons: [String] {
        var seen = Set<String>()
        return notes.values.flatMap(\.persons).filter { seen.insert(TextAnalysis.key($0)).inserted }
    }
}

// MARK: - Input

/// The note content the index needs, copied from the SwiftData model on the main actor so
/// indexing can run in the background.
struct IndexableNote: Sendable {
    let id: UUID
    let contentHash: String
    let title: String
    let createdAt: Date
    let kind: NoteKind
    let focus: RecordingFocus
    let languageCode: String
    let isFavorite: Bool
    let participants: [String]
    let bodyText: String
    let transcriptData: Data?
    let summary: NoteSummary?

    @MainActor
    init(note: Note) {
        id = note.id
        contentHash = Self.fingerprint(of: note)
        title = note.title
        createdAt = note.createdAt
        kind = note.kind
        focus = note.focus
        languageCode = note.language.languageCode
        isFavorite = note.isFavorite
        participants = note.participants
        bodyText = note.bodyText
        transcriptData = note.transcriptData
        summary = note.summary
    }

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .now,
        kind: NoteKind = .recording,
        focus: RecordingFocus = .general,
        languageCode: String = "de",
        isFavorite: Bool = false,
        participants: [String] = [],
        bodyText: String,
        segments: [TranscriptSegment] = [],
        summary: NoteSummary? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.kind = kind
        self.focus = focus
        self.languageCode = languageCode
        self.isFavorite = isFavorite
        self.participants = participants
        self.bodyText = bodyText
        self.transcriptData = segments.isEmpty ? nil : try? Transcript.encode(segments)
        self.summary = summary
        contentHash = UUID().uuidString
    }

    /// A fingerprint of everything the index uses, computed on every refresh for every note.
    ///
    /// It reads only small values of the note's row: `contentRevision` stands for the text,
    /// transcript and summary (it increases whenever one of them is replaced), the rest are
    /// the metadata the index stores. Neither the text nor the transcript file is loaded, so
    /// a refresh over hundreds of unchanged notes costs microseconds per note.
    @MainActor
    static func fingerprint(of note: Note) -> String {
        var hasher = SHA256()
        let parts = [
            String(KnowledgeIndex.formatVersion),
            String(note.contentRevision),
            note.title,
            note.participants.joined(separator: "\u{1F}"),
            note.focusRawValue,
            note.languageID,
            note.kindRawValue,
            String(note.isFavorite),
        ]
        for part in parts {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Building

/// Splits a note into passages and computes terms, embeddings, keywords and entities.
struct KnowledgeIndexBuilder: Sendable {
    let embedder: any SentenceEmbedding

    /// Passages aim for this many words: long enough for context, short enough for a precise
    /// embedding and for several passages to fit into the language model's context.
    static let targetPassageWords = 70
    static let maximumPassageDuration: TimeInterval = 60

    func entry(for note: IndexableNote) -> IndexedNote {
        let segments = note.transcriptData.flatMap { try? Transcript.decode($0) } ?? []
        var passages = segments.isEmpty
            ? textPassages(for: note)
            : transcriptPassages(for: note, segments: segments)
        passages += summaryPassages(for: note)

        // Entities and keywords come from the content only: section labels such as
        // "Zusammenfassung:" appear in every note and would otherwise connect all of them.
        let spokenText = segments.isEmpty ? note.bodyText : segments.map(\.text).joined(separator: " ")
        let summaryContent = note.summary.map(Self.summaryContent) ?? ""
        var entities = TextAnalysis.entities(in: [note.title, spokenText, summaryContent].joined(separator: "\n"))
        let owners = note.summary?.actionItems.compactMap(\.owner).filter { !TextAnalysis.isSpeakerLabel($0) } ?? []
        entities.persons = unique(entities.persons + owners)

        let summaryKeywords = (note.summary?.keywords ?? []) + (note.summary?.topics.map(\.title) ?? [])
        let textKeywords = TextAnalysis.keywords(in: spokenText, languageCode: note.languageCode, limit: 8)

        return IndexedNote(
            id: note.id,
            contentHash: note.contentHash,
            title: note.title,
            createdAt: note.createdAt,
            kind: note.kind,
            focus: note.focus,
            languageCode: note.languageCode,
            isFavorite: note.isFavorite,
            participants: note.participants,
            entities: entities,
            keywords: unique(summaryKeywords + textKeywords),
            topics: note.summary?.topics.map(\.title) ?? [],
            vector: EmbeddingVector.mean(of: passages.filter { $0.kind != .summary }.compactMap(\.vector))
                ?? EmbeddingVector.mean(of: passages.compactMap(\.vector)),
            passages: passages
        )
    }

    // MARK: Passages

    /// Consecutive segments grouped into passages. Each passage repeats the last segment of the
    /// previous one, so a statement at a boundary is still found together with its context.
    private func transcriptPassages(for note: IndexableNote, segments: [TranscriptSegment]) -> [IndexedPassage] {
        var passages: [IndexedPassage] = []
        var startIndex = 0
        while startIndex < segments.count {
            var endIndex = startIndex
            var words = 0
            while endIndex < segments.count {
                words += segments[endIndex].text.split(whereSeparator: \.isWhitespace).count
                let duration = segments[endIndex].end - segments[startIndex].start
                endIndex += 1
                if words >= Self.targetPassageWords || duration >= Self.maximumPassageDuration { break }
            }
            let group = segments[startIndex..<endIndex]
            let text = Transcript.plainText(of: Array(group))
            passages.append(makePassage(
                index: passages.count,
                note: note,
                kind: .transcript,
                text: text,
                start: group.first?.start
            ))
            // Overlap by one segment unless the passage is a single long segment.
            startIndex = endIndex - startIndex > 1 ? endIndex - 1 : endIndex
        }
        return passages
    }

    /// Documents and images: sentences grouped into paragraphs of similar size.
    private func textPassages(for note: IndexableNote) -> [IndexedPassage] {
        var passages: [IndexedPassage] = []
        var current: [String] = []
        var words = 0
        func flush() {
            guard !current.isEmpty else { return }
            passages.append(makePassage(index: passages.count, note: note, kind: .text, text: current.joined(separator: " "), start: nil))
            current = []
            words = 0
        }
        for sentence in TextChunker.sentences(in: note.bodyText) {
            current.append(sentence)
            words += sentence.split(whereSeparator: \.isWhitespace).count
            if words >= Self.targetPassageWords { flush() }
        }
        flush()
        return passages
    }

    /// The summary as its own passages: broad questions ("Was haben wir zum Budget entschieden?")
    /// are often answered best by the condensed version.
    private func summaryPassages(for note: IndexableNote) -> [IndexedPassage] {
        var parts = ["Titel: \(note.title)"]
        if let summary = note.summary {
            parts.append(Self.summaryText(summary))
        }
        let text = parts.joined(separator: "\n")
        // Very long summaries are split so each passage stays precise.
        let chunks = text.count > 1_200 ? TextChunker.sentences(in: text).chunked(maxCharacters: 900) : [text]
        return chunks.enumerated().map { offset, chunk in
            makePassage(
                index: 10_000 + offset,
                note: note,
                kind: .summary,
                text: chunk,
                start: nil,
                // The labels ("Zusammenfassung:", "Aufgaben:") are the same in every note and
                // would make every summary look similar to every question.
                embeddingText: Self.removingLabels(from: chunk)
            )
        }
    }

    private static let sectionLabels = ["Titel", "Zusammenfassung", "Kernpunkte", "Entscheidungen", "Aufgaben", "Offene Fragen", "Stichworte"]

    static func removingLabels(from text: String) -> String {
        text.split(separator: "\n").map { line in
            for label in sectionLabels where line.hasPrefix(label + ": ") {
                return String(line.dropFirst(label.count + 2))
            }
            return String(line)
        }.joined(separator: "\n")
    }

    /// The summary's sentences without section labels, for entity recognition.
    static func summaryContent(_ summary: NoteSummary) -> String {
        ([summary.overview] + summary.keyPoints + summary.decisions + summary.actionItems.map(\.task) + summary.openQuestions)
            .joined(separator: "\n")
    }

    static func summaryText(_ summary: NoteSummary) -> String {
        var lines = ["Zusammenfassung: \(summary.overview)"]
        if !summary.keyPoints.isEmpty { lines.append("Kernpunkte: " + summary.keyPoints.joined(separator: "; ")) }
        if !summary.decisions.isEmpty { lines.append("Entscheidungen: " + summary.decisions.joined(separator: "; ")) }
        if !summary.actionItems.isEmpty {
            let tasks = summary.actionItems.map { item in
                var text = item.task
                if let owner = item.owner { text += " (\(owner))" }
                if let due = item.due { text += " bis \(due)" }
                return text
            }
            lines.append("Aufgaben: " + tasks.joined(separator: "; "))
        }
        if !summary.openQuestions.isEmpty { lines.append("Offene Fragen: " + summary.openQuestions.joined(separator: "; ")) }
        if !summary.keywords.isEmpty { lines.append("Stichworte: " + summary.keywords.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    private func makePassage(
        index: Int,
        note: IndexableNote,
        kind: IndexedPassage.Kind,
        text: String,
        start: TimeInterval?,
        embeddingText: String? = nil
    ) -> IndexedPassage {
        let terms = TextAnalysis.terms(in: embeddingText ?? text, languageCode: note.languageCode)
        return IndexedPassage(
            id: "\(note.id.uuidString)-\(index)",
            noteID: note.id,
            kind: kind,
            text: text,
            start: start,
            termFrequencies: terms.reduce(into: [:]) { $0[$1, default: 0] += 1 },
            termCount: terms.count,
            vector: embedder.vector(for: embeddingText ?? text, languageCode: note.languageCode)
        )
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert(TextAnalysis.key($0)).inserted }
    }
}

private extension [String] {
    /// Joins consecutive strings into chunks of at most `maxCharacters` (single long strings stay whole).
    func chunked(maxCharacters: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for part in self {
            if !current.isEmpty, current.count + part.count + 1 > maxCharacters {
                chunks.append(current)
                current = ""
            }
            current += current.isEmpty ? part : " " + part
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
