//
//  QualityEvaluationTests.swift
//  NotifyAITests
//
//  How good the on-device analysis is, measured on labeled data: search (recall and rank),
//  speaker detection (diarization error rate on synthesized voices), spoken deadlines, the
//  question parser and chapter boundaries. Each test computes a metric and fails when it
//  drops below the level documented in docs/Quality.md; the failure message names the
//  measured value. A change that makes the analysis worse is noticed even if every
//  functional test still passes.
//

import AVFoundation
import Foundation
import Synchronization
@testable import NotifyAIAudio
@testable import NotifyAICore
@testable import NotifyAIExport
@testable import NotifyAIIntegrations
@testable import NotifyAIKnowledge
@testable import NotifyAILibrary
@testable import NotifyAINeuralModels
@testable import NotifyAIPersistence
@testable import NotifyAIProcessing
@testable import NotifyAIRecording
@testable import NotifyAIServices
@testable import NotifyAISettings
@testable import NotifyAISpeakers
@testable import NotifyAISummarization
@testable import NotifyAISupport
@testable import NotifyAITranscription
import Testing

// MARK: - Shared

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    calendar.locale = Locale(identifier: "de_DE")
    calendar.firstWeekday = 2
    return calendar
}()

/// Wednesday, 30 September 2026, 15:00.
private let reference = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 15))!

private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

/// Search without meaning vectors: measures the full-text part of the hybrid search alone.
private struct NoEmbedding: SentenceEmbedding {
    func vector(for text: String, languageCode: String) -> EmbeddingVector? { nil }
}

// MARK: - Search

/// `SearchEvaluationCorpus.json`: 25 transcripts, labeled questions and notes that belong
/// together. Several notes share a domain on purpose, so a topic alone does not find the answer.
private struct SearchCorpus: Decodable {
    struct Note: Decodable {
        let id: String
        let title: String
        let language: String
        let sentences: [String]
    }

    enum Kind: String, Decodable {
        /// Asked with the note's own words.
        case lexical
        /// Asked with other words than the note uses.
        case paraphrase
        /// Asked in another language than the note's.
        case crosslingual
        /// Answered by no note.
        case negative
    }

    struct Query: Decodable {
        let text: String
        let relevant: [String]
        let kind: Kind
    }

    struct Metrics {
        var recallAt1 = 0.0
        var recallAt3 = 0.0
        var mrr = 0.0
    }

    let notes: [Note]
    let queries: [Query]
    let related: [[String]]

    static let shared: SearchCorpus = {
        let url = Bundle(for: CorpusBundleMarker.self).url(forResource: "SearchEvaluationCorpus", withExtension: "json")!
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }()

    func queries(_ kind: Kind) -> [Query] {
        queries.filter { $0.kind == kind }
    }

    /// The index and the identifier of every note.
    func index(embedder: any SentenceEmbedding) -> (KnowledgeIndex, [String: UUID]) {
        let builder = KnowledgeIndexBuilder(embedder: embedder)
        var index = KnowledgeIndex()
        var ids: [String: UUID] = [:]
        for (offset, note) in notes.enumerated() {
            let segments = note.sentences.enumerated().map { position, text in
                TranscriptSegment(start: Double(position) * 10, end: Double(position) * 10 + 9, text: text)
            }
            let input = IndexableNote(
                title: note.title,
                createdAt: reference.addingTimeInterval(Double(-offset) * 86_400),
                languageCode: note.language,
                bodyText: note.sentences.joined(separator: " "),
                segments: segments
            )
            index.notes[input.id] = builder.entry(for: input)
            ids[note.id] = input.id
        }
        return (index, ids)
    }

    /// Recall at 1 and 3 and the mean reciprocal rank of the notes found.
    static func evaluate(_ queries: [Query], retriever: HybridRetriever, ids: [String: UUID]) -> Metrics {
        var metrics = Metrics()
        for query in queries {
            let ranking = retriever.search(SearchRequest(text: query.text, languageCode: "de")).notes.map(\.note.id)
            let relevant = Set(query.relevant.compactMap { ids[$0] })
            guard let rank = ranking.firstIndex(where: relevant.contains) else { continue }
            if rank == 0 { metrics.recallAt1 += 1 }
            if rank < 3 { metrics.recallAt3 += 1 }
            metrics.mrr += 1 / Double(rank + 1)
        }
        let count = Double(max(queries.count, 1))
        return Metrics(recallAt1: metrics.recallAt1 / count, recallAt3: metrics.recallAt3 / count, mrr: metrics.mrr / count)
    }

    /// Share of the questions that no note answers for which the search still names a note.
    static func falseHitRate(_ queries: [Query], retriever: HybridRetriever) -> Double {
        let hits = queries.filter { !retriever.search(SearchRequest(text: $0.text, languageCode: "de")).notes.isEmpty }
        return Double(hits.count) / Double(max(queries.count, 1))
    }
}

private final class CorpusBundleMarker {}

/// Remembers vectors, so evaluating many settings embeds every text once.
private final class CachingEmbedder: SentenceEmbedding {
    private let base: any SentenceEmbedding
    private let cache = Mutex<[String: EmbeddingVector?]>([:])

    init(_ base: any SentenceEmbedding) {
        self.base = base
    }

    func vector(for text: String, languageCode: String) -> EmbeddingVector? {
        let key = languageCode + "\u{1F}" + text
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let vector = base.vector(for: text, languageCode: languageCode)
        cache.withLock { $0[key] = vector }
        return vector
    }

    func space(for languageCode: String) -> String? {
        base.space(for: languageCode)
    }
}

private let contextualModelInstalled = ContextualSentenceEmbedder().modelStatus(for: "de") == .installed

@Suite("Quality: search")
struct SearchQualityTests {
    @Test("Without meaning vectors, questions with the note's own words find it")
    func lexicalQuestions() {
        let corpus = SearchCorpus.shared
        let (index, ids) = corpus.index(embedder: NoEmbedding())
        let retriever = HybridRetriever(index: index, embedder: NoEmbedding())
        let metrics = SearchCorpus.evaluate(corpus.queries(.lexical), retriever: retriever, ids: ids)
        #expect(metrics.recallAt1 >= QualityLevels.fullTextRecallAt1, "Recall@1 \(metrics.recallAt1)")
        let falseHits = SearchCorpus.falseHitRate(corpus.queries(.negative), retriever: retriever)
        #expect(falseHits <= QualityLevels.fullTextFalseHits, "false hits \(falseHits)")
    }

    @Test("Meaning vectors find notes asked about in other words, and nothing where nothing fits",
          .enabled(if: contextualModelInstalled))
    func meaningVectors() {
        let corpus = SearchCorpus.shared
        let embedder = CachingEmbedder(ContextualSentenceEmbedder())
        let (index, ids) = corpus.index(embedder: embedder)
        let retriever = HybridRetriever(index: index, embedder: embedder)

        let lexical = SearchCorpus.evaluate(corpus.queries(.lexical), retriever: retriever, ids: ids)
        let paraphrases = SearchCorpus.evaluate(corpus.queries(.paraphrase), retriever: retriever, ids: ids)
        let falseHits = SearchCorpus.falseHitRate(corpus.queries(.negative), retriever: retriever)
        #expect(lexical.recallAt1 >= QualityLevels.lexicalRecallAt1, "own words: Recall@1 \(lexical.recallAt1)")
        #expect(paraphrases.recallAt1 >= QualityLevels.paraphraseRecallAt1, "other words: Recall@1 \(paraphrases.recallAt1)")
        #expect(paraphrases.recallAt3 >= QualityLevels.paraphraseRecallAt3, "other words: Recall@3 \(paraphrases.recallAt3)")
        #expect(paraphrases.mrr >= QualityLevels.paraphraseMRR, "other words: MRR \(paraphrases.mrr)")
        #expect(falseHits <= QualityLevels.falseHits, "false hits \(falseHits)")

        // The vectors must add clearly over full text alone.
        let (plainIndex, plainIDs) = corpus.index(embedder: NoEmbedding())
        let plain = SearchCorpus.evaluate(corpus.queries(.paraphrase), retriever: HybridRetriever(index: plainIndex, embedder: NoEmbedding()), ids: plainIDs)
        #expect(paraphrases.mrr >= plain.mrr + 0.15, "with vectors \(paraphrases.mrr) vs. full text \(plain.mrr)")
    }
}

@Suite("Quality: related notes")
struct RelatedNotesQualityTests {
    /// For every labeled pair, whether each note lists the other among its first three
    /// related notes; and the share of all listed relations that are labeled. Unlabeled
    /// relations are not necessarily wrong, so precision is a lower bound.
    fileprivate static func evaluate(
        _ index: KnowledgeIndex, ids: [String: UUID], corpus: SearchCorpus, finder: RelatedNotesFinder
    ) -> (recallAt3: Double, precision: Double, listed: Int) {
        let pairs = Set(corpus.related.flatMap { pair in [[pair[0], pair[1]], [pair[1], pair[0]]] })
        let names = Dictionary(uniqueKeysWithValues: ids.map { ($1, $0) })
        var found = 0
        var listed = 0
        var labeled = 0
        for note in corpus.notes {
            let related = finder.related(to: ids[note.id]!, limit: 3).compactMap { names[$0.note.id] }
            listed += related.count
            labeled += related.filter { pairs.contains([note.id, $0]) }.count
            found += pairs.filter { $0[0] == note.id && related.contains($0[1]) }.count
        }
        return (Double(found) / Double(pairs.count), listed > 0 ? Double(labeled) / Double(listed) : 0, listed)
    }

    @Test("Notes that belong together are listed as related", .enabled(if: contextualModelInstalled))
    func relatedNotes() {
        let corpus = SearchCorpus.shared
        let (index, ids) = corpus.index(embedder: ContextualSentenceEmbedder())
        let result = Self.evaluate(index, ids: ids, corpus: corpus, finder: RelatedNotesFinder(index: index))
        #expect(result.recallAt3 >= QualityLevels.relatedRecallAt3, "found \(result.recallAt3)")
        #expect(result.precision >= QualityLevels.relatedPrecision, "precision \(result.precision)")
    }
}

// MARK: - Speaker detection

/// Spoken German from two system voices, with the exact time every sentence was spoken.
private enum SynthesizedConversation {
    static let sentences = [
        "Guten Morgen, wir sprechen heute über das Budget der Herbstkampagne.",
        "Danke. Ich habe die Zahlen der letzten Kampagne mitgebracht.",
        "Sehr gut. Wie viel haben wir im letzten Jahr für Anzeigen ausgegeben?",
        "Ungefähr zehntausend Euro, davon die Hälfte für soziale Netzwerke.",
        "Dann schlage ich vor, dass wir dieses Jahr zwölftausend Euro einplanen.",
        "Einverstanden. Ich kläre die Motive bis Freitag mit der Agentur.",
    ]

    /// The voices the reference value in docs/Quality.md was measured with, both part of macOS.
    /// Fixed by identifier: which German voices a Mac has, and in which order, differs (GitHub's
    /// runners list others first), and other voices give other results. Without both voices the
    /// suite is skipped.
    static let voiceIdentifiers = ["com.apple.voice.compact.de-DE.Anna", "com.apple.eloquence.de-DE.Eddy"]

    static var voices: [AVSpeechSynthesisVoice] {
        let voices = voiceIdentifiers.compactMap(AVSpeechSynthesisVoice.init(identifier:))
        return voices.count == voiceIdentifiers.count ? voices : []
    }

    static var isAvailable: Bool { voices.count == 2 }

    /// 16 kHz mono samples of the conversation and the speaker of every sentence's interval.
    @MainActor
    static func make() async throws -> (samples: [Float], truth: [(range: Range<Double>, speaker: Int)]) {
        let voices = voices
        let pause = [Float](repeating: 0, count: Int(0.5 * AudioFormat.sampleRate))
        var samples: [Float] = []
        var truth: [(Range<Double>, Int)] = []
        for (index, sentence) in sentences.enumerated() {
            let speaker = index % 2
            let speech = try await synthesize(sentence, voice: voices[speaker])
            let start = Double(samples.count) / AudioFormat.sampleRate
            samples += speech
            truth.append((start..<Double(samples.count) / AudioFormat.sampleRate, speaker))
            samples += pause
        }
        return (samples, truth)
    }

    @MainActor
    private static func synthesize(_ text: String, voice: AVSpeechSynthesisVoice) async throws -> [Float] {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        let synthesizer = AVSpeechSynthesizer()
        // Buffers are converted as they arrive; only samples leave the callback.
        let samples: [Float]? = await withCheckedContinuation { continuation in
            var collected: [Float] = []
            var failed = false
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    continuation.resume(returning: failed ? nil : collected)
                } else if let converted = try? convert(pcm) {
                    collected += converted
                } else {
                    failed = true
                }
            }
        }
        return try #require(samples, "Converting the synthesized speech failed")
    }

    private static func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        let output = AudioFormat.makeProcessingFormat()
        let converter = try #require(AVAudioConverter(from: buffer.format, to: output))
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate) + 1_024
        let converted = try #require(AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity))
        var provided = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if provided {
                status.pointee = .endOfStream
                return nil
            }
            provided = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        guard let channel = converted.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
    }

    /// The share of spoken time attributed to the wrong speaker or to nobody, with the best
    /// mapping of detected to true speakers (the usual diarization error rate without
    /// false alarms in pauses).
    static func errorRate(turns: [SpeakerTurn], truth: [(range: Range<Double>, speaker: Int)]) -> Double {
        let step = 0.01
        var frames: [(truth: Int, detected: Int?)] = []
        for (range, speaker) in truth {
            var time = range.lowerBound
            while time < range.upperBound {
                let detected = turns.first { $0.start <= time && time < $0.end }?.speaker
                frames.append((speaker, detected))
                time += step
            }
        }
        guard !frames.isEmpty else { return 1 }
        let detectedSpeakers = Set(frames.compactMap(\.detected))
        // Each detected speaker counts as the true speaker it overlaps most.
        var mapping: [Int: Int] = [:]
        for detected in detectedSpeakers {
            let overlaps = Dictionary(grouping: frames.filter { $0.detected == detected }, by: \.truth).mapValues(\.count)
            mapping[detected] = overlaps.max { $0.value < $1.value }?.key
        }
        let wrong = frames.filter { frame in frame.detected.flatMap { mapping[$0] } != frame.truth }.count
        return Double(wrong) / Double(frames.count)
    }
}

@Suite("Quality: speaker detection", .enabled(if: SynthesizedConversation.isAvailable), .timeLimit(.minutes(2)))
@MainActor
struct SpeakerQualityTests {
    @Test("Two voices in a conversation are told apart")
    func diarizationErrorRate() async throws {
        let (samples, truth) = try await SynthesizedConversation.make()
        let turns = SpeakerDiarizer().turns(for: samples)
        let errorRate = SynthesizedConversation.errorRate(turns: turns, truth: truth)
        #expect(Set(turns.map(\.speaker)).count == 2, "found \(Set(turns.map(\.speaker)).count) speakers")
        #expect(errorRate <= QualityLevels.diarizationErrorRate, "DER \(errorRate)")
    }
}

// MARK: - Deadlines and questions

@Suite("Quality: understanding")
struct UnderstandingQualityTests {
    /// Deadlines as they are said in meetings, recorded on Wednesday, 30 September 2026.
    private static let deadlines: [(String, Date?)] = [
        ("heute noch", day(2026, 9, 30)), ("bis morgen", day(2026, 10, 1)), ("übermorgen", day(2026, 10, 2)),
        ("bis Freitag", day(2026, 10, 2)), ("am Montag", day(2026, 10, 5)), ("nächsten Dienstag", day(2026, 10, 6)),
        ("bis Ende der Woche", day(2026, 10, 2)), ("nächste Woche", day(2026, 10, 9)), ("in zwei Wochen", day(2026, 10, 14)),
        ("in 3 Tagen", day(2026, 10, 3)), ("bis zum 15. Oktober", day(2026, 10, 15)), ("bis 12.10.", day(2026, 10, 12)),
        ("am 1. November", day(2026, 11, 1)), ("bis Ende des Monats", day(2026, 9, 30)), ("ASAP", day(2026, 9, 30)),
        ("tomorrow", day(2026, 10, 1)), ("next Friday", day(2026, 10, 2)), ("by October 20", day(2026, 10, 20)),
        ("irgendwann", nil), ("wenn es passt", nil),
    ]

    @Test("Spoken deadlines become the right day")
    func deadlineAccuracy() {
        let resolver = DueDateResolver(calendar: calendar)
        let wrong = Self.deadlines.filter { resolver.resolve($0.0, relativeTo: reference) != $0.1 }
        let accuracy = 1 - Double(wrong.count) / Double(Self.deadlines.count)
        #expect(accuracy >= QualityLevels.deadlineAccuracy, "wrong: \(wrong.map(\.0))")
    }

    /// Questions with the filters they imply.
    private static let questions: [(String, Timeframe?, [String], Set<NoteKind>?)] = [
        ("Was hat Anna letzte Woche zum Budget gesagt?", .lastWeek, ["Anna"], nil),
        ("Welche Aufgaben habe ich diese Woche übernommen?", .thisWeek, [], nil),
        ("Zeig mir alle Aufnahmen von gestern", .yesterday, [], [.recording]),
        ("Was stand im PDF über die Lieferzeit?", nil, [], [.document]),
        ("Was hat Ben im letzten Monat entschieden?", .lastMonth, ["Ben"], nil),
        ("Welche Fragen sind noch offen?", nil, [], nil),
        ("Was wurde heute mit Anna besprochen?", .today, ["Anna"], nil),
        ("Zeig mir die Fotos von dieser Woche", .thisWeek, [], [.image]),
        ("Was hat Lisa dieses Jahr zum Ausflug gesagt?", .thisYear, ["Lisa"], nil),
        ("Wie hoch war der Umsatz?", nil, [], nil),
    ]

    @Test("Questions are understood with the right filters")
    func questionUnderstanding() {
        let parser = RuleBasedQueryParser(now: reference, calendar: calendar)
        let wrong = Self.questions.filter { question, timeframe, persons, kinds in
            let plan = parser.plan(for: question, knownPersons: ["Anna Schmidt", "Ben Weber", "Lisa Wagner"])
            let expectedRange = timeframe?.dateRange(now: reference, calendar: calendar)
            return plan.filters.dateRange != expectedRange || plan.filters.persons != persons || plan.filters.kinds != kinds
        }
        let accuracy = 1 - Double(wrong.count) / Double(Self.questions.count)
        #expect(accuracy >= QualityLevels.questionAccuracy, "wrong: \(wrong.map(\.0))")
    }
}

// MARK: - Chapters

@Suite("Quality: chapters")
struct ChapterQualityTests {
    /// A 50-minute meeting about four topics of 12.5 minutes each, one sentence every 20 s.
    private static func transcript() -> (segments: [TranscriptSegment], topicChanges: [TimeInterval]) {
        let topics = [
            ["Das Budget der Kampagne", "die Anzeigen auf Instagram", "die Motive der Agentur", "die Kosten für Werbung"],
            ["Das Release der App", "der Fehler beim Login", "die Tickets im Sprint", "die Tests auf dem iPhone"],
            ["Die Einstellung der Entwicklerin", "das Gehalt im Vertrag", "der Starttermin im Januar", "die Einarbeitung im Team"],
            ["Der Umzug ins neue Büro", "die Kartons für das Archiv", "der Transporter am Samstag", "die Schlüssel für die Räume"],
        ]
        let topicDuration: TimeInterval = 12.5 * 60
        var segments: [TranscriptSegment] = []
        var time: TimeInterval = 0
        for (topicIndex, phrases) in topics.enumerated() {
            var sentence = 0
            while time < Double(topicIndex + 1) * topicDuration {
                let text = "\(phrases[sentence % phrases.count]) wurde besprochen, \(phrases[(sentence + 1) % phrases.count]) ebenfalls."
                segments.append(TranscriptSegment(start: time, end: time + 18, text: text))
                time += 20
                sentence += 1
            }
        }
        return (segments, [1, 2, 3].map { Double($0) * topicDuration })
    }

    @Test("Chapters begin where the topic changes")
    func boundaries() {
        let (segments, topicChanges) = Self.transcript()
        let chapters = ChapterSegmenter().chapters(in: segments, isComplete: true, languageCode: "de")
        let boundaries = chapters.dropFirst().map(\.start)
        let errors = topicChanges.map { change in boundaries.map { abs($0 - change) }.min() ?? .infinity }
        let meanError = errors.reduce(0, +) / Double(errors.count)
        #expect(chapters.count == 4, "\(chapters.count) chapters")
        #expect(meanError <= QualityLevels.chapterBoundaryError, "mean error \(meanError) s")
    }
}

// MARK: - Levels

/// The levels the analysis reaches today (docs/Quality.md). Raise them when it improves;
/// lowering one needs a reason in the commit.
private enum QualityLevels {
    // Search on SearchEvaluationCorpus.json, without Apple Intelligence's query expansion.
    /// Measured 0.96 (coverage alone, no meaning vectors).
    static let fullTextRecallAt1 = 0.9
    /// Measured 0.25: a question no note answers still shares a rare word with some note.
    static let fullTextFalseHits = 0.25
    /// Measured 0.96 with meaning vectors.
    static let lexicalRecallAt1 = 0.9
    /// Measured 0.46 / 0.58 / 0.52 for questions in other words (full text alone: 0.23 / 0.29 / 0.27).
    static let paraphraseRecallAt1 = 0.4
    static let paraphraseRecallAt3 = 0.5
    static let paraphraseMRR = 0.45
    /// Measured 0.125 (one of eight questions). Only eight such questions: one more is allowed.
    static let falseHits = 0.25
    /// Measured 0.44 / 0.20 (previous relative score with sentence embeddings: 0.22 / 0.13).
    static let relatedRecallAt3 = 0.4
    static let relatedPrecision = 0.18
    /// Measured 0.059 on the synthesized conversation.
    static let diarizationErrorRate = 0.1
    static let deadlineAccuracy = 1.0
    static let questionAccuracy = 1.0
    /// Measured 6.7 s; a sentence lasts 20 s.
    static let chapterBoundaryError: TimeInterval = 30
}
