//
//  KnowledgeIndex.swift
//  NotifyAIKnowledge
//

import CryptoKit
import Foundation
import NotifyAICore
import NotifyAIPersistence
import NotifyAISummarization
import NotifyAISupport

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
    /// Search term frequencies (see `TextAnalysis.terms`), as positions in the note's `terms`.
    var termFrequencies = PassageTerms()
    let termCount: Int
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
    /// The user's labels ("Samsung"); a question can be limited to them.
    let labels: [String]
    let entities: NamedEntities
    let keywords: [String]
    let topics: [String]
    /// Mean of all window vectors: what the note is about as a whole.
    let vector: EmbeddingVector?
    /// The space of `vector` and `passageVectors` (`SentenceEmbedding.space`); `nil` without vectors.
    let embeddingSpace: String?
    /// Meaning vectors of windows of about 25 words, several per passage.
    let passageVectors: PassageVectors
    /// The search terms of all passages; `IndexedPassage.termFrequencies` refers to them.
    let terms: NoteTerms
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
    /// 5: named speakers count as persons of the note.
    /// 6: labels; summaries across several notes index only their summary.
    /// 7: search terms stored once per note (`NoteTerms`) instead of once per passage.
    /// 8: contextual embeddings of 25-word windows (`ContextualSentenceEmbedder`, `PassageVectors`).
    static let formatVersion = 8

    var formatVersion = Self.formatVersion
    public var notes: [UUID: IndexedNote] = [:]

    public var passageCount: Int { notes.values.reduce(0) { $0 + $1.passages.count } }

    /// All distinct persons, for recognizing names in questions.
    var knownPersons: [String] {
        var seen = Set<String>()
        return notes.values.flatMap(\.persons).filter { seen.insert(TextAnalysis.key($0)).inserted }
    }

    /// All distinct labels, for recognizing them in questions.
    var knownLabels: [String] {
        NoteLabel.unique(notes.values.sorted { $0.createdAt < $1.createdAt }.flatMap(\.labels))
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
    let labels: [String]
    let bodyText: String
    let transcriptData: Data?
    let summary: NoteSummary?

    /// - Parameter embeddingSpace: The space the note's vectors would have now; a note
    ///   indexed in another space (the model was installed or updated) is indexed again.
    @MainActor
    init(note: Note, embeddingSpace: String?) {
        id = note.id
        contentHash = Self.fingerprint(of: note, embeddingSpace: embeddingSpace)
        title = note.title
        createdAt = note.createdAt
        kind = note.kind
        focus = note.focus
        languageCode = note.language.languageCode
        isFavorite = note.isFavorite
        participants = note.participants
        labels = note.labels
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
        labels: [String] = [],
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
        self.labels = labels
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
    static func fingerprint(of note: Note, embeddingSpace: String?) -> String {
        var hasher = SHA256()
        let parts = [
            String(KnowledgeIndex.formatVersion),
            embeddingSpace ?? "",
            String(note.contentRevision),
            note.title,
            note.participants.joined(separator: "\u{1F}"),
            note.labelKeys,
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
        // A summary across several notes is made from their summaries: indexing its source
        // text would find the same statements twice.
        var drafts = if note.kind == .collection {
            [PassageDraft]()
        } else if segments.isEmpty {
            textPassages(for: note)
        } else {
            transcriptPassages(for: note, segments: segments)
        }
        drafts += summaryPassages(for: note)
        let terms = NoteTerms(terms: drafts.flatMap(\.terms))
        let passages = drafts.map { draft in
            var passage = draft.passage
            passage.termFrequencies = terms.frequencies(of: draft.terms)
            return passage
        }
        let windowVectors = windowVectors(of: drafts, languageCode: note.languageCode)

        // Entities and keywords come from the content only: section labels such as
        // "Zusammenfassung:" appear in every note and would otherwise connect all of them.
        let spokenText = segments.isEmpty ? note.bodyText : segments.map(\.text).joined(separator: " ")
        let summaryContent = note.summary.map(Self.summaryContent) ?? ""
        var entities = TextAnalysis.entities(in: [note.title, spokenText, summaryContent].joined(separator: "\n"))
        let owners = note.summary?.actionItems.compactMap(\.owner).filter { !TextAnalysis.isSpeakerLabel($0) } ?? []
        // Named and recognized speakers: "Was hat Anna gesagt?" finds the notes she speaks in.
        let speakers = segments.compactMap(\.speaker).filter { !TextAnalysis.isSpeakerLabel($0) }
        entities.persons = unique(entities.persons + owners + speakers)

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
            labels: note.labels,
            entities: entities,
            keywords: unique(summaryKeywords + textKeywords),
            topics: note.summary?.topics.map(\.title) ?? [],
            vector: EmbeddingVector.mean(of: windowVectors.filter { passages[$0.passage].kind != .summary }.map(\.vector))
                ?? EmbeddingVector.mean(of: windowVectors.map(\.vector)),
            embeddingSpace: windowVectors.isEmpty ? nil : embedder.space(for: note.languageCode),
            passageVectors: PassageVectors(windowVectors),
            terms: terms,
            passages: passages
        )
    }

    // MARK: Vectors

    /// Vectors aim for this many words: the measured optimum on `SearchEvaluationCorpus.json`
    /// (70 words: 35 % of paraphrased questions found first, 25 words: 50 %, single sentences:
    /// 48 %, but five times as many vectors).
    static let targetWindowWords = 25

    /// Consecutive units (segments, sentences, summary items) grouped into windows of about
    /// `targetWindowWords`, overlapping by one unit like the passages.
    static func windows(of units: [String]) -> [String] {
        var windows: [String] = []
        var start = 0
        while start < units.count {
            var end = start
            var words = 0
            while end < units.count {
                words += units[end].split(whereSeparator: \.isWhitespace).count
                end += 1
                if words >= targetWindowWords { break }
            }
            windows.append(units[start..<end].joined(separator: " "))
            start = end - start > 1 && end < units.count ? end - 1 : end
        }
        return windows
    }

    private func windowVectors(of drafts: [PassageDraft], languageCode: String) -> [(passage: Int, vector: EmbeddingVector)] {
        drafts.enumerated().flatMap { position, draft in
            Self.windows(of: draft.units).compactMap { window in
                embedder.vector(for: window, languageCode: languageCode).map { (position, $0) }
            }
        }
    }

    // MARK: Passages

    /// A passage with its terms, before they are counted against the note's `NoteTerms`, and
    /// the units its vector windows are made of.
    private struct PassageDraft {
        let passage: IndexedPassage
        let terms: [String]
        let units: [String]
    }

    /// Consecutive segments grouped into passages. Each passage repeats the last segment of the
    /// previous one, so a statement at a boundary is still found together with its context.
    private func transcriptPassages(for note: IndexableNote, segments: [TranscriptSegment]) -> [PassageDraft] {
        var passages: [PassageDraft] = []
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
                PassageSource(kind: .transcript, text: text, start: group.first?.start, units: group.map(\.text))
            ))
            // Overlap by one segment unless the passage is a single long segment.
            startIndex = endIndex - startIndex > 1 ? endIndex - 1 : endIndex
        }
        return passages
    }

    /// Documents and images: sentences grouped into paragraphs of similar size.
    private func textPassages(for note: IndexableNote) -> [PassageDraft] {
        var passages: [PassageDraft] = []
        var current: [String] = []
        var words = 0
        func flush() {
            guard !current.isEmpty else { return }
            passages.append(makePassage(
                index: passages.count,
                note: note,
                PassageSource(kind: .text, text: current.joined(separator: " "), start: nil, units: current)
            ))
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
    private func summaryPassages(for note: IndexableNote) -> [PassageDraft] {
        var parts = ["Titel: \(note.title)"]
        if !note.labels.isEmpty {
            parts.append("Labels: " + note.labels.joined(separator: ", "))
        }
        if let summary = note.summary {
            parts.append(Self.summaryText(summary))
        }
        let text = parts.joined(separator: "\n")
        // Very long summaries are split so each passage stays precise.
        let chunks = text.count > 1_200 ? TextChunker.sentences(in: text).chunked(maxCharacters: 900) : [text]
        return chunks.enumerated().map { offset, chunk in
            // The labels ("Zusammenfassung:", "Aufgaben:") are the same in every note and
            // would make every summary look similar to every question.
            let content = Self.removingLabels(from: chunk)
            return makePassage(index: 10_000 + offset, note: note, PassageSource(
                kind: .summary,
                text: chunk,
                start: nil,
                units: content.split(separator: "\n").flatMap { $0.split(separator: "; ") }.map(String.init),
                termText: content
            ))
        }
    }

    private static let sectionLabels = ["Titel", "Labels", "Zusammenfassung", "Kernpunkte", "Entscheidungen", "Aufgaben", "Offene Fragen", "Stichworte"]

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

    /// What a passage is made of.
    private struct PassageSource {
        let kind: IndexedPassage.Kind
        let text: String
        let start: TimeInterval?
        /// Segments, sentences or summary items: what its vector windows are made of.
        let units: [String]
        /// The text its search terms come from, if not `text`.
        var termText: String?
    }

    private func makePassage(index: Int, note: IndexableNote, _ source: PassageSource) -> PassageDraft {
        let terms = TextAnalysis.terms(in: source.termText ?? source.text, languageCode: note.languageCode)
        let passage = IndexedPassage(
            id: "\(note.id.uuidString)-\(index)",
            noteID: note.id,
            kind: source.kind,
            text: source.text,
            start: source.start,
            termCount: terms.count
        )
        return PassageDraft(passage: passage, terms: terms, units: source.units)
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
