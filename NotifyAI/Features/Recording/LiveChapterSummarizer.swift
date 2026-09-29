//
//  LiveChapterSummarizer.swift
//  NotifyAI
//

import Foundation
import OSLog

/// Condenses finished chapters while the recording is still running.
///
/// The live transcript is cut with the same `ChapterSegmenter` the processing uses after
/// the recording. A chapter is only closed once enough transcript follows it, so its
/// boundaries and key are final; its digest goes into the `ChapterDigestStore` and is reused
/// one to one after stopping. For a three-hour meeting only the last chapter and the final
/// summary remain: the summary is ready within seconds instead of minutes.
///
/// Work is deliberately gentle: one chapter at a time at background priority, only with
/// Apple Intelligence (the extractive fallback is fast anyway), and not at all while the
/// device is hot or in Low Power Mode. Skipped chapters are simply condensed after the
/// recording.
@MainActor
final class LiveChapterSummarizer {
    private let summarization: SummarizationService
    private let store: ChapterDigestStore
    private let segmenter = ChapterSegmenter()
    private let logger = Logger.summarization
    /// How often the transcript is checked for newly finished chapters.
    private let checkInterval: TimeInterval = 30

    private var noteID: UUID?
    private var context: SummaryRequest?
    /// Markers set so far; passages marked as important are emphasised in the chapter digest.
    var markers: [Marker] = []
    private var segments: [TranscriptSegment] = []
    private var handledKeys = Set<String>()
    private var pending: [(chapter: TranscriptChapter, number: Int)] = []
    private var worker: Task<Void, Never>?
    private var lastCheck = Date.distantPast
    private var checkTask: Task<Void, Never>?

    init(summarization: SummarizationService, store: ChapterDigestStore) {
        self.summarization = summarization
        self.store = store
    }

    func start(noteID: UUID, context: SummaryRequest) {
        stop()
        self.noteID = noteID
        self.context = context
    }

    /// Called whenever the live transcript grows. Cheap: checks at most every `checkInterval`.
    func transcriptDidChange(_ segments: [TranscriptSegment]) {
        self.segments = segments
        guard let context, noteID != nil, checkTask == nil,
              Date.now.timeIntervalSince(lastCheck) >= checkInterval else { return }
        lastCheck = .now
        let languageCode = context.language.languageCode
        let segmenter = segmenter
        checkTask = Task { [weak self] in
            let chapters = await Task.detached(priority: .background) {
                // Normalized exactly like the transcript that is saved after stopping,
                // so chapter keys match.
                segmenter.chapters(in: Transcript.normalized(segments), isComplete: false, languageCode: languageCode)
            }.value
            guard let self else { return }
            checkTask = nil
            enqueue(chapters)
        }
    }

    /// Stops condensing. A chapter in progress is abandoned; the processing redoes it.
    func stop() {
        worker?.cancel()
        checkTask?.cancel()
        worker = nil
        checkTask = nil
        pending = []
        handledKeys = []
        markers = []
        segments = []
        noteID = nil
        context = nil
        lastCheck = .distantPast
    }

    // MARK: - Private

    private func enqueue(_ chapters: [TranscriptChapter]) {
        for (index, chapter) in chapters.enumerated() where !handledKeys.contains(chapter.key) {
            handledKeys.insert(chapter.key)
            pending.append((chapter, index + 1))
        }
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !pending.isEmpty, let noteID, let context else { return }
        worker = Task(priority: .background) { [weak self] in
            while let self, !Task.isCancelled, let next = self.nextChapter() {
                await self.condense(next.chapter, number: next.number, noteID: noteID, context: context)
            }
            self?.worker = nil
        }
    }

    private func nextChapter() -> (chapter: TranscriptChapter, number: Int)? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    private func condense(_ chapter: TranscriptChapter, number: Int, noteID: UUID, context: SummaryRequest) async {
        // Only worth it with the language model, and never at the expense of the device.
        guard summarization.usesLanguageModel(for: context.language), !DeviceLoad.isConstrained else {
            logger.info("Skipping live chapter \(number, privacy: .public): model unavailable or device constrained")
            return
        }
        if await store.digest(noteID: noteID, key: chapter.key) != nil { return }
        let markedPassages = markers
            .filter { $0.time >= chapter.start && $0.time < chapter.end }
            .map { Transcript.text(in: $0.highlightRange(), of: segments) }
        let request = ChapterRequest(
            number: number,
            // The final number of chapters is unknown while recording; it only appears in the prompt.
            count: max(number, 1),
            start: chapter.start,
            end: chapter.end,
            text: chapter.text,
            context: context,
            markedPassages: markedPassages
        )
        do {
            let digest = try await summarization.digest(request)
            guard !Task.isCancelled, digest.source == .appleIntelligence else { return }
            await store.save(digest, noteID: noteID, key: chapter.key)
            logger.info("Condensed live chapter \(number, privacy: .public)")
        } catch {
            logger.error("Live chapter digest failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
