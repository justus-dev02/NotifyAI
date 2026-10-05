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
import NotifyAICore
@testable import NotifyAIPersistence
@testable import NotifyAIServices
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

private enum SearchCorpus {
    struct Query {
        let text: String
        let relevant: Int
        /// Asked with other words than the note uses.
        let isParaphrase: Bool
    }

    static let notes: [(title: String, sentences: [String])] = [
        ("Marketing-Runde", [
            "Das Budget der Herbstkampagne liegt bei 12.000 Euro.",
            "Die Anzeigen auf Instagram starten am 15. Oktober.",
            "Ben stimmt die Motive mit der Agentur ab.",
        ]),
        ("Vorlesung Statistik", [
            "Die Varianz beschreibt die Streuung einer Zufallsvariable.",
            "Die Standardabweichung ist die Wurzel der Varianz.",
            "In der Klausur kommt die Normalverteilung dran.",
        ]),
        ("Sprint-Planung", [
            "Das Release der App ist für den 20. Oktober geplant.",
            "Der Fehler beim Login muss vorher behoben werden.",
            "Tickets ohne Schätzung kommen in den nächsten Sprint.",
        ]),
        ("Kundengespräch Müller", [
            "Die Firma Müller bekommt ein Angebot über 48.000 Euro.",
            "Die Lieferzeit beträgt sechs Wochen.",
            "Der Einkauf möchte bis Freitag eine Rückmeldung.",
        ]),
        ("Bewerbungsgespräch Frontend", [
            "Die Kandidatin hat fünf Jahre Erfahrung mit React und TypeScript.",
            "Ihre Gehaltsvorstellung liegt bei 65.000 Euro.",
            "Sie könnte im Januar anfangen.",
        ]),
        ("Arzttermin", [
            "Der Blutdruck war mit 135 zu 85 leicht erhöht.",
            "Die Ärztin hat Ramipril verschrieben.",
            "Die nächste Kontrolle ist in drei Monaten.",
        ]),
        ("Umzug", [
            "Der Transporter ist für Samstag um acht Uhr reserviert.",
            "Wir brauchen noch vierzig Umzugskartons.",
            "Die alte Wohnung muss bis Ende November gekündigt werden.",
        ]),
        ("Datenschutz-Workshop", [
            "Für den Newsletter brauchen wir eine Einwilligung nach DSGVO.",
            "Bewerbungsunterlagen werden nach sechs Monaten gelöscht.",
            "Das Verzeichnis der Verarbeitungstätigkeiten wird aktualisiert.",
        ]),
        ("Quartalszahlen", [
            "Der Umsatz im dritten Quartal lag bei 2,4 Millionen Euro.",
            "Der Gewinn ist um acht Prozent gestiegen.",
            "Für das vierte Quartal erwarten wir ein leichtes Wachstum.",
        ]),
        ("Teamausflug", [
            "Der Teamausflug geht in die Kletterhalle am Ostbahnhof.",
            "Termin ist der 9. Oktober um 16 Uhr.",
            "Anmeldungen bitte bis Montag an Lisa.",
        ]),
    ]

    static let queries: [Query] = [
        Query(text: "Wie hoch ist das Budget der Herbstkampagne?", relevant: 0, isParaphrase: false),
        Query(text: "Was ist die Standardabweichung?", relevant: 1, isParaphrase: false),
        Query(text: "Wann ist das Release der App?", relevant: 2, isParaphrase: false),
        Query(text: "Welches Angebot bekommt die Firma Müller?", relevant: 3, isParaphrase: false),
        Query(text: "Welche Gehaltsvorstellung hat die Kandidatin?", relevant: 4, isParaphrase: false),
        Query(text: "Welches Medikament wurde verschrieben?", relevant: 5, isParaphrase: false),
        Query(text: "Wann ist der Transporter reserviert?", relevant: 6, isParaphrase: false),
        Query(text: "Brauchen wir für den Newsletter eine Einwilligung?", relevant: 7, isParaphrase: false),
        Query(text: "Wie hoch war der Umsatz im dritten Quartal?", relevant: 8, isParaphrase: false),
        Query(text: "Wohin geht der Teamausflug?", relevant: 9, isParaphrase: false),
        Query(text: "Wie viel Geld steht für die Werbung zur Verfügung?", relevant: 0, isParaphrase: true),
        Query(text: "Wie stark schwanken die Werte um den Mittelwert?", relevant: 1, isParaphrase: true),
        Query(text: "Probleme beim Anmelden in der Anwendung", relevant: 2, isParaphrase: true),
        Query(text: "Wie lange dauert die Auslieferung beim Kunden?", relevant: 3, isParaphrase: true),
        Query(text: "Welche Programmiersprachen kennt die Bewerberin?", relevant: 4, isParaphrase: true),
        Query(text: "Wie waren die Werte beim Doktor?", relevant: 5, isParaphrase: true),
        Query(text: "Bis wann müssen wir den Mietvertrag beenden?", relevant: 6, isParaphrase: true),
        Query(text: "Wann werden Bewerbungen vernichtet?", relevant: 7, isParaphrase: true),
        Query(text: "Wie hat sich der Profit entwickelt?", relevant: 8, isParaphrase: true),
        Query(text: "Bei wem melde ich mich zum Klettern an?", relevant: 9, isParaphrase: true),
    ]

    /// The index and the identifier of every note, in the order of `notes`.
    static func index(embedder: any SentenceEmbedding) -> (KnowledgeIndex, [UUID]) {
        let builder = KnowledgeIndexBuilder(embedder: embedder)
        var index = KnowledgeIndex()
        var ids: [UUID] = []
        for (offset, note) in notes.enumerated() {
            let segments = note.sentences.enumerated().map { position, text in
                TranscriptSegment(start: Double(position) * 10, end: Double(position) * 10 + 9, text: text)
            }
            let input = IndexableNote(
                title: note.title,
                createdAt: reference.addingTimeInterval(Double(-offset) * 86_400),
                bodyText: note.sentences.joined(separator: " "),
                segments: segments
            )
            index.notes[input.id] = builder.entry(for: input)
            ids.append(input.id)
        }
        return (index, ids)
    }

    /// Recall at 1 and 3 and the mean reciprocal rank over `queries`.
    static func evaluate(_ queries: [Query], embedder: any SentenceEmbedding) -> (recallAt1: Double, recallAt3: Double, mrr: Double) {
        let (index, ids) = index(embedder: embedder)
        let retriever = HybridRetriever(index: index, embedder: embedder)
        var hitsAt1 = 0.0
        var hitsAt3 = 0.0
        var reciprocalRanks = 0.0
        for query in queries {
            let ranking = retriever.search(SearchRequest(text: query.text, languageCode: "de")).notes.map(\.note.id)
            guard let rank = ranking.firstIndex(of: ids[query.relevant]) else { continue }
            if rank == 0 { hitsAt1 += 1 }
            if rank < 3 { hitsAt3 += 1 }
            reciprocalRanks += 1 / Double(rank + 1)
        }
        let count = Double(queries.count)
        return (hitsAt1 / count, hitsAt3 / count, reciprocalRanks / count)
    }
}

@Suite("Quality: search")
struct SearchQualityTests {
    @Test("Questions with the note's own words find it")
    func lexicalQuestions() {
        let metrics = SearchCorpus.evaluate(SearchCorpus.queries.filter { !$0.isParaphrase }, embedder: NoEmbedding())
        #expect(metrics.recallAt1 >= 0.9, "Recall@1 \(metrics.recallAt1)")
        #expect(metrics.mrr >= 0.9, "MRR \(metrics.mrr)")
    }

    @Test("Meaning vectors find notes asked about with other words",
          .enabled(if: SentenceEmbedder().supports(languageCode: "de")))
    func paraphrasedQuestions() {
        let paraphrases = SearchCorpus.queries.filter(\.isParaphrase)
        let lexical = SearchCorpus.evaluate(paraphrases, embedder: NoEmbedding())
        let hybrid = SearchCorpus.evaluate(paraphrases, embedder: SentenceEmbedder())
        #expect(hybrid.recallAt3 >= QualityLevels.paraphraseRecallAt3, "Recall@3 \(hybrid.recallAt3)")
        // The semantic part must add something over full text alone.
        #expect(hybrid.mrr >= lexical.mrr, "hybrid \(hybrid.mrr) vs. full text \(lexical.mrr)")
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

    static var voices: [AVSpeechSynthesisVoice] {
        // A female voice and one that is not (some voices report no gender).
        let german = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "de-DE" }
        guard let first = german.first(where: { $0.gender == .female }),
              let second = german.first(where: { $0.gender != .female })
        else { return [] }
        return [first, second]
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
    /// Without Apple Intelligence's query expansion (as in tests), a note only matches with a
    /// full-text hit; meaning vectors only reorder. Paraphrases are therefore mostly missed.
    static let paraphraseRecallAt3 = 0.2
    /// Measured 0.059 on the synthesized conversation.
    static let diarizationErrorRate = 0.1
    static let deadlineAccuracy = 1.0
    static let questionAccuracy = 1.0
    /// Measured 6.7 s; a sentence lasts 20 s.
    static let chapterBoundaryError: TimeInterval = 30
}
