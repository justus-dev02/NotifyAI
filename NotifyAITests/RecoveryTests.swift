//
//  RecoveryTests.swift
//  NotifyAITests
//
//  How the app recovers from interruptions: system interruptions of a recording, jobs
//  stopped by a recording or by the end of background time, and summaries whose parts the
//  language model cannot process or that do not fit into its context.
//

import Foundation
import FoundationModels
@testable import NotifyAI
import NotifyAICore
@testable import NotifyAIPersistence
@testable import NotifyAIServices
import Synchronization
import Testing

// MARK: - Interruptions of a recording

@Suite("Interruptions of a recording")
struct InterruptionPolicyTests {
    @Test("An interruption pauses a running recording and resumes it afterwards")
    func pausesAndResumes() {
        var policy = InterruptionPolicy()
        #expect(policy.interruptionBegan(isRecording: true) == .pause)
        #expect(policy.interruptionEnded(shouldResume: true, isPaused: true) == .resume)
    }

    @Test("A pause the user chose before the interruption stays")
    func manualPauseStays() {
        var policy = InterruptionPolicy()
        #expect(policy.interruptionBegan(isRecording: false) == .none)
        #expect(policy.interruptionEnded(shouldResume: true, isPaused: true) == .none)
    }

    @Test("Pausing or resuming during the interruption hands the recording back to the user")
    func userTakesOver() {
        var policy = InterruptionPolicy()
        #expect(policy.interruptionBegan(isRecording: true) == .pause)
        // The user resumes and pauses again while the call is still going on.
        policy.userTookOver()
        #expect(policy.interruptionEnded(shouldResume: true, isPaused: true) == .none)
    }

    @Test("Without the system's permission to resume, the recording stays paused")
    func noResumeWithoutPermission() {
        var policy = InterruptionPolicy()
        #expect(policy.interruptionBegan(isRecording: true) == .pause)
        #expect(policy.interruptionEnded(shouldResume: false, isPaused: true) == .none)
        // A second end notification must not resume either.
        #expect(policy.interruptionEnded(shouldResume: true, isPaused: true) == .none)
    }

    @Test("A device failure during the interruption is not resumed automatically")
    func deviceFailureDuringInterruption() {
        var policy = InterruptionPolicy()
        #expect(policy.interruptionBegan(isRecording: true) == .pause)
        policy.userTookOver()
        #expect(!policy.isPausedByInterruption)
        #expect(policy.interruptionEnded(shouldResume: true, isPaused: true) == .none)
    }
}

// MARK: - Summaries with limitations

/// Answers the summarizer's requests from a script and records them.
final class ScriptedResponder: LanguageModelResponder {
    struct Request: Sendable {
        let type: String
        let prompt: String
    }

    private let requests = Mutex<[Request]>([])
    private let answer: @Sendable (_ type: Any.Type, _ prompt: String) async throws -> Any

    init(answer: @escaping @Sendable (_ type: Any.Type, _ prompt: String) async throws -> Any) {
        self.answer = answer
    }

    var recorded: [Request] { requests.withLock { $0 } }

    func respond<Content: Generable>(generating type: Content.Type, instructions: String, prompt: String) async throws -> Content {
        requests.withLock { $0.append(Request(type: String(describing: type), prompt: prompt)) }
        guard let content = try await answer(type, prompt) as? Content else {
            throw TestError()
        }
        return content
    }
}

enum Scripted {
    static func notes(_ points: [String]) -> PartialNotes {
        PartialNotes(keyPoints: points, decisions: [], actionItems: [], openQuestions: [])
    }

    static let summary = GeneratedSummary(
        title: "Titel",
        overview: "Überblick",
        keyPoints: ["Kernpunkt"],
        decisions: [],
        actionItems: [],
        openQuestions: [],
        topics: [],
        keywords: []
    )

    static let chapter = GeneratedChapterDigest(
        title: "Kapitel",
        overview: "Überblick",
        keyPoints: ["Kernpunkt"],
        decisions: [],
        actionItems: [],
        openQuestions: []
    )

    /// Sentences that form a transcript of about `tokens` tokens (estimated).
    static func transcript(tokens: Int, topic: String) -> String {
        let sentence = "Wir haben über \(topic) gesprochen, und Anna übernimmt die nächsten Schritte bis Freitag."
        let count = Int((Double(tokens * 3) / Double(sentence.count + 1)).rounded(.up))
        return Array(repeating: sentence, count: count).joined(separator: " ")
    }

    static func request(_ text: String, marked: [String] = []) -> SummaryRequest {
        SummaryRequest(text: text, language: .german, focus: .general, kind: .recording, markedPassages: marked)
    }
}

@Suite("Summaries with limitations")
struct SummaryLimitationTests {
    private let measure = TextChunker.estimatedTokens
    private let budget = FoundationModelSummarizer.inputTokenBudget

    @Test("An excerpt the model refuses is condensed without it; the rest keeps the model's notes")
    func failingExcerptStaysLocal() async throws {
        let responder = ScriptedResponder { type, prompt in
            if type == PartialNotes.self {
                if prompt.hasPrefix("Excerpt 2 of") { throw TestError() }
                return Scripted.notes(["Modellnotiz."])
            }
            return Scripted.summary
        }
        let text = Scripted.transcript(tokens: 1_500, topic: "das Budget") + " "
            + Scripted.transcript(tokens: 1_500, topic: "die Website") + " "
            + Scripted.transcript(tokens: 1_500, topic: "den Messestand")
        let summary = try await FoundationModelSummarizer(responder: responder, measure: measure)
            .summarize(Scripted.request(text)) { _ in }

        let excerpts = responder.recorded.filter { $0.type.contains("PartialNotes") && $0.prompt.hasPrefix("Excerpt") }
        #expect(excerpts.count >= 3)
        #expect(summary.source == .appleIntelligence)
        #expect(summary.processingNotes.count == 1)
        #expect(summary.processingNotes.first?.contains("1 von \(excerpts.count)") == true)

        // The final request contains the model's notes and the refused excerpt's key sentences.
        let final = try #require(responder.recorded.last)
        #expect(final.type.contains("GeneratedSummary"))
        #expect(final.prompt.contains("Point: Modellnotiz."))
        #expect(final.prompt.contains("Point: Wir haben über"))
    }

    @Test("Only when every excerpt fails does the summary fail (and the service falls back)")
    func allExcerptsFail() async throws {
        let responder = ScriptedResponder { type, _ in
            if type == PartialNotes.self { throw TestError() }
            return Scripted.summary
        }
        let text = Scripted.transcript(tokens: 4_000, topic: "das Budget")
        await #expect(throws: TestError.self) {
            _ = try await FoundationModelSummarizer(responder: responder, measure: measure).summarize(Scripted.request(text)) { _ in }
        }

        let service = SummarizationService(
            languageModel: FoundationModelSummarizer(responder: responder, measure: measure),
            fallback: ExtractiveSummarizer(),
            availability: { _ in .available }
        )
        let fallback = try await service.summarize(Scripted.request(text)) { _ in }
        #expect(fallback.source == .extractive)
        #expect(fallback.fallbackReason != nil)
    }

    @Test("Marked passages are part of the budget; those that do not fit are named")
    func markedPassagesStayInBudget() async throws {
        let responder = ScriptedResponder { type, _ in
            if type == PartialNotes.self { return Scripted.notes(["Modellnotiz."]) }
            return Scripted.summary
        }
        // The text alone fits, but not together with eight long marked passages.
        let text = Scripted.transcript(tokens: 1_650, topic: "das Budget")
        let marked = (1...8).map { Scripted.transcript(tokens: 150, topic: "Stelle \($0)") }
        let summary = try await FoundationModelSummarizer(responder: responder, measure: measure)
            .summarize(Scripted.request(text, marked: marked)) { _ in }

        for request in responder.recorded {
            let size = await measure(request.prompt)
            #expect(size <= budget, "a request of \(size) tokens exceeds the budget of \(budget)")
        }
        let final = try #require(responder.recorded.last)
        #expect(final.prompt.contains("The user marked these passages"))
        #expect(final.prompt.contains("Stelle 1"))
        #expect(!final.prompt.contains("Stelle 8"))
        #expect(summary.processingNotes.contains { $0.contains("markierte Stellen") })
    }

    @Test("Notes that do not fit even after merging are shortened, and the summary says so")
    func shortenedNotesAreFlagged() async throws {
        let longPoint = String(repeating: "Ein ausführlicher Punkt über das Budget ", count: 6) + "."
        let responder = ScriptedResponder { type, prompt in
            guard type == PartialNotes.self else { return Scripted.summary }
            // Excerpts produce far too much; merging never shrinks it below the budget.
            let count = prompt.hasPrefix("Excerpt") ? 60 : 25
            return Scripted.notes(Array(repeating: longPoint, count: count))
        }
        let text = Scripted.transcript(tokens: 2_500, topic: "das Budget")
        let summary = try await FoundationModelSummarizer(responder: responder, measure: measure)
            .summarize(Scripted.request(text)) { _ in }

        let final = try #require(responder.recorded.last)
        #expect(final.type.contains("GeneratedSummary"))
        #expect(await measure(final.prompt) <= budget)
        #expect(summary.processingNotes.contains { $0.contains("gekürzt") })
    }

    @Test("Cancellation is not mistaken for a refused excerpt")
    func cancellationPropagates() async throws {
        let responding = TestGate()
        let responder = ScriptedResponder { _, _ in
            responding.signal()
            // Answers only when cancelled, like a model call that is interrupted.
            let cancelled = TestGate()
            await withTaskCancellationHandler {
                await cancelled.wait()
            } onCancel: {
                cancelled.signal()
            }
            throw CancellationError()
        }
        let text = Scripted.transcript(tokens: 4_000, topic: "das Budget")
        let task = Task {
            try await FoundationModelSummarizer(responder: responder, measure: TextChunker.estimatedTokens).summarize(Scripted.request(text)) { _ in }
        }
        await responding.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(responder.recorded.count == 1)
    }

    @Test("A chapter reports refused excerpts; the note's summary names them")
    func chapterLimitations() async throws {
        let responder = ScriptedResponder { type, prompt in
            if type == PartialNotes.self {
                if prompt.hasPrefix("Excerpt 1 of") { throw TestError() }
                return Scripted.notes(["Modellnotiz."])
            }
            if type == GeneratedChapterDigest.self { return Scripted.chapter }
            return Scripted.summary
        }
        let summarizer = FoundationModelSummarizer(responder: responder, measure: measure)
        let context = Scripted.request("")
        let long = ChapterRequest(
            number: 1, count: 2, start: 0, end: 600,
            text: Scripted.transcript(tokens: 4_000, topic: "das Budget"),
            context: context,
            markedPassages: []
        )
        let short = ChapterRequest(
            number: 2, count: 2, start: 600, end: 1_200,
            text: Scripted.transcript(tokens: 300, topic: "die Website"),
            context: context,
            markedPassages: []
        )

        let digest = try await summarizer.digest(long)
        #expect(digest.failedExcerpts == 1)
        #expect(!digest.wasShortened)

        let service = SummarizationService(languageModel: summarizer, fallback: ExtractiveSummarizer(), availability: { _ in .available })
        let summary = try await service.summarize(
            context,
            chapters: [long, short],
            keys: ["a", "b"],
            storedIn: NoteDigests(store: ChapterDigestStore(directory: nil), noteID: UUID())
        ) { _ in }
        #expect(summary.chapters.count == 2)
        #expect(summary.processingNotes.contains { $0.contains("In 1 Kapiteln") })
    }

    @Test("Summaries and chapter digests stored before the limitations existed still decode")
    func olderFormatsDecode() throws {
        let summary = NoteSummary(overview: "Alt", source: .appleIntelligence, processingNotes: ["Hinweis"])
        var summaryJSON = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any])
        summaryJSON["processingNotes"] = nil
        let decodedSummary = try JSONDecoder().decode(NoteSummary.self, from: JSONSerialization.data(withJSONObject: summaryJSON))
        #expect(decodedSummary.processingNotes.isEmpty)
        #expect(decodedSummary.overview == "Alt")

        let digest = ChapterDigest(title: "Alt", overview: "", source: .appleIntelligence, failedExcerpts: 2, wasShortened: true)
        var digestJSON = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(digest)) as? [String: Any])
        digestJSON["failedExcerpts"] = nil
        digestJSON["wasShortened"] = nil
        let decodedDigest = try JSONDecoder().decode(ChapterDigest.self, from: JSONSerialization.data(withJSONObject: digestJSON))
        #expect(decodedDigest.failedExcerpts == 0)
        #expect(!decodedDigest.wasShortened)
        #expect(try JSONDecoder().decode(ChapterDigest.self, from: JSONEncoder().encode(digest)) == digest)
    }
}
