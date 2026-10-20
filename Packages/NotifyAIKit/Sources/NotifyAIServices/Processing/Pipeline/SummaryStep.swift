//
//  SummaryStep.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore
import NotifyAIPersistence

/// Step 3: summarizes the note, links every summary item to its transcript position and
/// gives an untitled recording its keyword title.
///
/// Recordings long enough for chapters (see `ChapterSegmenter`) are summarized chapter by
/// chapter; intermediate digests live in the `ChapterDigestStore` until the note is ready.
@MainActor
struct SummaryStep {
    let summarization: SummarizationService
    let digestStore: ChapterDigestStore
    let embedder: any SentenceEmbedding
    let templates: TemplateLookup

    func needsToRun(for note: Note, options: ProcessingOptions) -> Bool {
        options.forceSummary || note.summary == nil
    }

    func run(_ note: Note, options: ProcessingOptions, context: ProcessingContext) async throws {
        context.setStage(.summarizing, nil)
        let segments = note.decodedTranscript()
        let input = SummaryInput(note: note, segments: segments, template: templates.guidance(for: note))

        if options.forceSummary {
            // "Neu zusammenfassen" starts from scratch instead of reusing earlier chapters.
            await digestStore.remove(noteID: input.noteID)
        }
        var summary = try await summarize(input, progress: context.progress)
        try Task.checkCancellation()

        let finish = await BackgroundWork.run(priority: .utility) { [summary, embedder] in
            SummaryFinishing(summary: summary, input: input, embedder: embedder)
        }
        try Task.checkCancellation()
        summary = finish.summary
        summary.sourceTimes = finish.sourceTimes

        note.summary = summary
        if !note.isTitleUserDefined {
            if input.isRecording {
                // Recordings: keywords from the conversation plus the recording date.
                note.title = AutomaticTitle.make(keywords: finish.titleKeywords, date: input.createdAt)
            } else if let title = summary.suggestedTitle {
                note.title = title
            }
        }
    }

    private func summarize(_ input: SummaryInput, progress: @escaping @Sendable (Double) -> Void) async throws -> NoteSummary {
        let chapters = input.isAudio
            ? await BackgroundWork.run(priority: .utility) {
                ChapterSegmenter().chapters(in: input.segments, isComplete: true, languageCode: input.languageCode)
            }
            : []
        guard chapters.count >= 2 else {
            return try await summarization.summarize(input.request, progress: progress)
        }
        let requests = chapters.enumerated().map { index, chapter in
            ChapterRequest(
                number: index + 1,
                count: chapters.count,
                start: chapter.start,
                end: chapter.end,
                text: chapter.text,
                context: input.request,
                markedPassages: input.markedPassages(from: chapter.start, to: chapter.end)
            )
        }
        return try await summarization.summarize(
            input.request,
            chapters: requests,
            keys: chapters.map(\.key),
            storedIn: NoteDigests(store: digestStore, noteID: input.noteID),
            progress: progress
        )
    }
}

/// Everything the summary needs from the note, copied once so the work can leave the main actor.
struct SummaryInput: Sendable {
    let noteID: UUID
    let request: SummaryRequest
    let segments: [TranscriptSegment]
    let markers: [Marker]
    let duration: TimeInterval
    let createdAt: Date
    let languageCode: String
    let isAudio: Bool
    let isRecording: Bool
    /// Participants and speakers, the people a task can belong to.
    let people: [String]

    @MainActor
    init(note: Note, segments: [TranscriptSegment], template: TemplateGuidance? = nil) {
        noteID = note.id
        self.segments = segments
        var seen = Set<String>()
        people = (note.participants + note.speakers.map(\.label) + segments.compactMap(\.speaker))
            .filter { seen.insert($0).inserted }
        markers = note.markers
        duration = note.duration
        createdAt = note.createdAt
        languageCode = note.language.languageCode
        isAudio = note.kind.hasAudio
        isRecording = note.kind == .recording
        request = SummaryRequest(
            text: note.bodyText,
            language: note.language,
            focus: note.focus,
            kind: note.kind,
            markedPassages: note.markers.map {
                Transcript.text(in: $0.highlightRange(duration: note.duration), of: segments)
            },
            recordedAt: note.createdAt,
            participants: note.participants,
            template: template
        )
    }

    /// Transcript passages the user marked inside `from..<to`.
    func markedPassages(from start: TimeInterval, to end: TimeInterval) -> [String] {
        markers
            .filter { $0.time >= start && $0.time < end }
            .map { Transcript.text(in: $0.highlightRange(duration: duration), of: segments) }
    }
}

/// Work after summarizing that does not need the main actor: checking the tasks, source
/// positions and title keywords.
private struct SummaryFinishing: Sendable {
    /// The summary without items the text does not support, with precise tasks.
    let summary: NoteSummary
    let sourceTimes: [String: TimeInterval]
    let titleKeywords: [String]

    init(summary generated: NoteSummary, input: SummaryInput, embedder: any SentenceEmbedding) {
        var summary = SummaryGrounding(text: input.request.text, languageCode: input.languageCode).apply(to: generated)
        let tasks = ActionItemRefiner(
            text: input.request.text,
            segments: input.segments,
            languageCode: input.languageCode,
            people: input.people,
            recordedAt: input.createdAt
        )
        .refine(summary.actionItems)
        summary.actionItems = tasks.items
        self.summary = summary
        // The passage a task was quoted from is a more precise source than a similar one.
        sourceTimes = SummaryEvidenceLinker(embedder: embedder)
            .sourceTimes(for: summary, segments: input.segments, languageCode: input.languageCode)
            .merging(tasks.sourceTimes) { _, quoted in quoted }
        titleKeywords = input.isRecording
            ? AutomaticTitle.keywords(
                summary: summary,
                transcriptText: input.segments.map(\.text).joined(separator: " "),
                languageCode: input.languageCode
            )
            : []
    }
}
