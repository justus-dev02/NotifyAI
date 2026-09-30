//
//  Summarizer.swift
//  NotifyAI
//

import Foundation
import FoundationModels
import NotifyAICore
import OSLog

/// Everything a summarizer needs to know about a note.
struct SummaryRequest: Sendable {
    var text: String
    var language: TranscriptionLanguage
    var focus: RecordingFocus
    var kind: NoteKind
    /// Transcript passages the user marked as important.
    var markedPassages: [String]
    /// When the note was recorded or imported; resolves "bis Freitag" and similar.
    var recordedAt: Date = .now
    /// Names the user entered before recording.
    var participants: [String] = []
}

protocol Summarizer: Sendable {
    func summarize(_ request: SummaryRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> NoteSummary

    /// Condenses one chapter of a long recording.
    func digest(_ chapter: ChapterRequest) async throws -> ChapterDigest

    /// Turns the chapter digests of a long recording into the summary of the whole.
    func combine(_ chapters: [TimedDigest], request: SummaryRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> NoteSummary
}

/// One chapter to condense, with the context of the whole note.
struct ChapterRequest: Sendable {
    let number: Int
    let count: Int
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    /// Language, focus, date and participants of the note; `text` of the note is not used.
    let context: SummaryRequest
    let markedPassages: [String]
}

struct TimedDigest: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let digest: ChapterDigest
}

extension Summarizer {
    /// Default: summarize the chapter like a short note.
    func digest(_ chapter: ChapterRequest) async throws -> ChapterDigest {
        var request = chapter.context
        request.text = chapter.text
        request.markedPassages = chapter.markedPassages
        let summary = try await summarize(request) { _ in }
        return ChapterDigest(
            title: summary.suggestedTitle ?? summary.topics.first?.title ?? summary.keywords.first ?? String(localized: "Kapitel \(chapter.number)"),
            overview: summary.overview,
            keyPoints: summary.keyPoints,
            decisions: summary.decisions,
            actionItems: summary.actionItems,
            openQuestions: summary.openQuestions,
            source: summary.source
        )
    }

    /// Default: merge the chapters without a language model.
    func combine(_ chapters: [TimedDigest], request: SummaryRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> NoteSummary {
        progress(1)
        return ChapterMerger.merge(chapters)
    }
}

/// Combines chapter digests without a language model: lists are concatenated and
/// de-duplicated, key points are taken evenly from all chapters.
enum ChapterMerger {
    static func merge(_ chapters: [TimedDigest]) -> NoteSummary {
        let digests = chapters.map(\.digest)
        var keyPoints: [String] = []
        var round = 0
        while keyPoints.count < 8, digests.contains(where: { $0.keyPoints.count > round }) {
            for digest in digests where digest.keyPoints.count > round && keyPoints.count < 8 {
                keyPoints.append(digest.keyPoints[round])
            }
            round += 1
        }
        let overview = digests.prefix(3).map(\.overview).filter { !$0.isEmpty }.joined(separator: " ")
        return NoteSummary(
            suggestedTitle: digests.first?.title,
            overview: overview,
            keyPoints: keyPoints,
            decisions: unique(digests.flatMap(\.decisions), limit: 8),
            actionItems: Array(digests.flatMap(\.actionItems).prefix(15)),
            openQuestions: unique(digests.flatMap(\.openQuestions), limit: 6),
            topics: digests.map { SummaryTopic(title: $0.title, points: Array($0.keyPoints.prefix(3))) },
            source: digests.allSatisfy { $0.source == .appleIntelligence } ? .appleIntelligence : .extractive
        )
    }

    private static func unique(_ values: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        return Array(values.filter { seen.insert(TextAnalysis.key($0)).inserted }.prefix(limit))
    }
}

/// Whether Apple's on-device language model can be used right now.
enum LanguageModelAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)

    static func current(for language: TranscriptionLanguage) -> LanguageModelAvailability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            guard model.supportsLocale(language.locale) else {
                return .unavailable(reason: String(localized: "Apple Intelligence unterstützt \(language.displayName) noch nicht."))
            }
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable(reason: String(localized: "Dieses Gerät unterstützt Apple Intelligence nicht."))
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(reason: String(localized: "Apple Intelligence ist in den Systemeinstellungen deaktiviert."))
        case .unavailable(.modelNotReady):
            return .unavailable(reason: String(localized: "Das Sprachmodell von Apple Intelligence wird noch geladen. Bitte versuche es später erneut."))
        case .unavailable:
            return .unavailable(reason: String(localized: "Apple Intelligence ist derzeit nicht verfügbar."))
        }
    }
}

/// Chooses the best available summarizer and falls back to extraction when the
/// language model is unavailable or refuses the content.
struct SummarizationService: Sendable {
    private let languageModel: any Summarizer
    private let fallback: any Summarizer
    private let availability: @Sendable (TranscriptionLanguage) -> LanguageModelAvailability

    init(
        languageModel: any Summarizer = FoundationModelSummarizer(),
        fallback: any Summarizer = ExtractiveSummarizer(),
        availability: @escaping @Sendable (TranscriptionLanguage) -> LanguageModelAvailability = LanguageModelAvailability.current
    ) {
        self.languageModel = languageModel
        self.fallback = fallback
        self.availability = availability
    }

    /// Whether chapters are condensed with the language model (otherwise extractively).
    func usesLanguageModel(for language: TranscriptionLanguage) -> Bool {
        availability(language) == .available
    }

    /// Condenses a single chapter, e.g. while the recording is still running.
    func digest(_ chapter: ChapterRequest) async throws -> ChapterDigest {
        guard usesLanguageModel(for: chapter.context.language) else {
            return try await fallback.digest(chapter)
        }
        do {
            return try await languageModel.digest(chapter)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Logger.summarization.error("Language model chapter digest failed: \(error.localizedDescription, privacy: .public)")
            return try await fallback.digest(chapter)
        }
    }

    /// Summarizes a long recording chapter by chapter.
    ///
    /// Every digest is stored in `store` right away and reused on the next attempt, so an
    /// interrupted summary continues where it stopped. Between chapters the work pauses
    /// while the device is hot. Progress: chapters take 85 %, the final summary the rest.
    func summarize(
        _ request: SummaryRequest,
        chapters: [ChapterRequest],
        keys: [String],
        noteID: UUID,
        store: ChapterDigestStore,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> NoteSummary {
        let usesModel = usesLanguageModel(for: request.language)
        let expectedSource: NoteSummary.Source = usesModel ? .appleIntelligence : .extractive
        var timed: [TimedDigest] = []

        for (index, chapter) in chapters.enumerated() {
            try Task.checkCancellation()
            let key = keys[index]
            let digest: ChapterDigest
            if let stored = await store.digest(noteID: noteID, key: key), stored.source == expectedSource {
                digest = stored
            } else {
                await DeviceLoad.waitWhileHot()
                try Task.checkCancellation()
                do {
                    digest = try await self.digest(chapter)
                } catch SummarizationError.emptyInput {
                    // A chapter without speech (a long break) must not fail the whole summary.
                    digest = ChapterDigest(title: String(localized: "Kapitel \(chapter.number)"), overview: "", source: expectedSource)
                }
                await store.save(digest, noteID: noteID, key: key)
            }
            timed.append(TimedDigest(start: chapter.start, end: chapter.end, digest: digest))
            progress(0.85 * Double(index + 1) / Double(chapters.count))
        }

        await DeviceLoad.waitWhileHot()
        var summary: NoteSummary
        if usesModel {
            do {
                summary = try await languageModel.combine(timed, request: request) { fraction in
                    progress(0.85 + 0.15 * fraction)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Logger.summarization.error("Combining chapters failed: \(error.localizedDescription, privacy: .public)")
                summary = ChapterMerger.merge(timed)
                summary.fallbackReason = String(localized: "Apple Intelligence konnte die Kapitel nicht zusammenführen; die Zusammenfassung wurde aus den Kapiteln zusammengestellt.")
            }
        } else {
            summary = try await fallback.combine(timed, request: request, progress: progress)
            if case .unavailable(let reason) = availability(request.language) {
                summary.fallbackReason = reason
            }
        }
        summary.chapters = timed.map {
            SummaryChapter(start: $0.start, end: $0.end, title: $0.digest.title, overview: $0.digest.overview)
        }
        progress(1)
        return summary
    }

    func summarize(_ request: SummaryRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> NoteSummary {
        switch availability(request.language) {
        case .available:
            do {
                return try await languageModel.summarize(request, progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Logger.summarization.error("Language model summary failed: \(error.localizedDescription, privacy: .public)")
                var summary = try await fallback.summarize(request, progress: progress)
                summary.fallbackReason = String(localized: "Apple Intelligence konnte diesen Text nicht zusammenfassen.")
                return summary
            }
        case .unavailable(let reason):
            var summary = try await fallback.summarize(request, progress: progress)
            summary.fallbackReason = reason
            return summary
        }
    }
}
