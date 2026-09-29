//
//  LongRecordingTests.swift
//  NotifyAITests
//

import AVFoundation
import Foundation
import Testing
@testable import NotifyAI

// MARK: - Fixtures

private enum LongFixture {
    static let budget = ["Budget", "Kampagne", "Anzeigen", "Agentur", "Kosten", "Werbung"]
    static let servers = ["Server", "Datenbank", "Migration", "Backup", "Deployment", "Rechenzentrum"]
    static let vacation = ["Urlaub", "Hotel", "Flug", "Strand", "Reiseplanung", "Mietwagen"]

    /// One 20-second segment per step: budget until 11 min, servers until 22 min, vacation until 40 min.
    static func segments(until end: TimeInterval = 40 * 60) -> [TranscriptSegment] {
        stride(from: 0.0, to: end, by: 20).enumerated().map { index, start in
            let words = start < 660 ? budget : start < 1_320 ? servers : vacation
            let text = "Wir sprechen über \(words[index % words.count]) und \(words[(index + 2) % words.count]) sowie \(words[(index + 4) % words.count])."
            return TranscriptSegment(start: start, end: start + 18, text: text)
        }
    }
}

private actor CallCounter {
    private(set) var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}

private struct CountingSummarizer: Summarizer {
    let counter: CallCounter
    /// Throws on this call number (1-based), simulating an interruption.
    var failOnCall: Int?

    func summarize(_ request: SummaryRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> NoteSummary {
        let call = await counter.increment()
        if call == failOnCall { throw CancellationError() }
        return NoteSummary(suggestedTitle: "Kapitel", overview: "Überblick \(call)", keyPoints: ["Punkt \(call)"], source: .appleIntelligence)
    }
}

// MARK: - Chapters

@Suite("Chapters of long recordings")
struct ChapterSegmenterTests {
    private let segmenter = ChapterSegmenter()

    @Test("Chapters start where the topic changes")
    func topicBoundaries() {
        let chapters = segmenter.chapters(in: LongFixture.segments(), isComplete: true, languageCode: "de")
        #expect(chapters.count == 4)
        #expect(chapters[0].start == 0)
        #expect(chapters[1].start == 660)
        #expect(chapters[2].start == 1_320)
        #expect(chapters.last?.end == LongFixture.segments().last?.end)
        // Chapters cover every segment exactly once.
        #expect(chapters.map(\.segmentRange.count).reduce(0, +) == LongFixture.segments().count)
    }

    @Test("Short recordings get no chapters")
    func shortRecording() {
        #expect(segmenter.chapters(in: LongFixture.segments(until: 15 * 60), isComplete: true, languageCode: "de").isEmpty)
    }

    @Test("Chapters cut while recording are identical to the final ones")
    func deterministicWhileRecording() {
        let all = LongFixture.segments()
        let final = segmenter.chapters(in: all, isComplete: true, languageCode: "de")
        for minutes in stride(from: 5, through: 40, by: 3) {
            let prefix = Array(all.prefix { $0.start < Double(minutes * 60) })
            let live = segmenter.chapters(in: prefix, isComplete: false, languageCode: "de")
            // Every chapter closed while recording must exist unchanged in the final result.
            for chapter in live {
                #expect(final.contains(chapter), "Chapter at \(chapter.start) s differs after \(minutes) min")
            }
        }
    }

    @Test("Keys ignore speaker labels added after recording")
    func keysIgnoreSpeakers() {
        let plain = LongFixture.segments()
        let labelled = plain.map { segment -> TranscriptSegment in
            var copy = segment
            copy.speaker = "Ich"
            return copy
        }
        let lhs = segmenter.chapters(in: plain, isComplete: true, languageCode: "de").map(\.key)
        let rhs = segmenter.chapters(in: labelled, isComplete: true, languageCode: "de").map(\.key)
        #expect(lhs == rhs)
    }
}

@Suite("Chapter summaries")
struct ChapterSummaryTests {
    private func chapterRequests() -> ([ChapterRequest], [String]) {
        let context = SummaryRequest(text: "", language: .german, focus: .meeting, kind: .recording, markedPassages: [])
        let chapters = ChapterSegmenter().chapters(in: LongFixture.segments(), isComplete: true, languageCode: "de")
        let requests = chapters.enumerated().map { index, chapter in
            ChapterRequest(number: index + 1, count: chapters.count, start: chapter.start, end: chapter.end, text: chapter.text, context: context, markedPassages: [])
        }
        return (requests, chapters.map(\.key))
    }

    @Test("Stored digests are reused, so an interrupted summary continues")
    func resumesAfterInterruption() async throws {
        let (requests, keys) = chapterRequests()
        let store = ChapterDigestStore(directory: try StorageLocations.temporary().processingDirectory)
        let noteID = UUID()
        let request = requests[0].context

        // First attempt: interrupted at the third chapter.
        let firstCounter = CallCounter()
        let failing = CountingSummarizer(counter: firstCounter, failOnCall: 3)
        let failingService = SummarizationService(languageModel: failing, fallback: failing, availability: { _ in .available })
        await #expect(throws: CancellationError.self) {
            _ = try await failingService.summarize(request, chapters: requests, keys: keys, noteID: noteID, store: store) { _ in }
        }
        #expect(await store.count(noteID: noteID) == 2)

        // Second attempt: only the missing chapters are condensed.
        let secondCounter = CallCounter()
        let working = CountingSummarizer(counter: secondCounter)
        let service = SummarizationService(languageModel: working, fallback: working, availability: { _ in .available })
        let summary = try await service.summarize(request, chapters: requests, keys: keys, noteID: noteID, store: store) { _ in }
        #expect(await secondCounter.count == requests.count - 2)
        #expect(summary.chapters.count == requests.count)
        #expect(summary.chapters.map(\.start) == requests.map(\.start))
    }

    @Test("Digests survive on disk")
    func persistedDigests() async throws {
        let directory = try StorageLocations.temporary().processingDirectory
        let noteID = UUID()
        let digest = ChapterDigest(title: "Budget", overview: "Das Budget steht.", keyPoints: ["12.000 Euro"], source: .appleIntelligence)
        await ChapterDigestStore(directory: directory).save(digest, noteID: noteID, key: "a")
        let reloaded = ChapterDigestStore(directory: directory)
        #expect(await reloaded.digest(noteID: noteID, key: "a") == digest)
        await reloaded.remove(noteID: noteID)
        #expect(await ChapterDigestStore(directory: directory).digest(noteID: noteID, key: "a") == nil)
    }

    @Test("Merging without a language model takes points from every chapter")
    func merge() {
        let chapters = (1...3).map { number in
            TimedDigest(start: Double(number) * 600, end: Double(number + 1) * 600, digest: ChapterDigest(
                title: "Kapitel \(number)",
                overview: "Überblick \(number).",
                keyPoints: ["A\(number)", "B\(number)"],
                decisions: ["Entscheidung"],
                source: .extractive
            ))
        }
        let summary = ChapterMerger.merge(chapters)
        #expect(summary.keyPoints.prefix(3) == ["A1", "A2", "A3"])
        #expect(summary.decisions == ["Entscheidung"])
        #expect(summary.topics.map(\.title) == ["Kapitel 1", "Kapitel 2", "Kapitel 3"])
        #expect(summary.source == .extractive)
    }
}

@Suite("Processing long recordings")
@MainActor
struct LongRecordingProcessingTests {
    @Test("Long recordings are summarized by chapter and the intermediate digests are removed")
    func chapteredProcessing() async throws {
        let store = try NoteStore(locations: try StorageLocations.temporary(), inMemory: true)
        let digestStore = ChapterDigestStore(directory: nil)
        let segments = LongFixture.segments()
        let engine = MockTranscriptionEngine(kind: .appleSpeech, segments: segments)
        let coordinator = ProcessingCoordinator(
            store: store,
            settings: makeIsolatedSettings(),
            transcription: TranscriptionService(appleSpeech: engine, whisper: engine),
            summarization: SummarizationService(languageModel: MockSummarizer(), fallback: MockSummarizer(), availability: { _ in .available }),
            diarizer: SpeakerDiarizer(),
            digestStore: digestStore
        )
        let note = Note(title: "Workshop", isTitleUserDefined: true, kind: .recording, status: .queued)
        let fileName = NoteStore.recordingFileName(for: note.id)
        note.audioFileName = fileName
        note.duration = 40 * 60
        try Data([0]).write(to: store.locations.audioURL(fileName: fileName))
        try store.insert(note)

        coordinator.enqueue(.process(note.id))
        for _ in 0..<300 where note.status != .ready && note.status != .failed {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(note.status == .ready)
        #expect(note.summary?.chapters.count == 4)
        #expect(await digestStore.count(noteID: note.id) == 0)
    }
}

// MARK: - Speaker detection streaming

@Suite("Streaming speaker detection")
struct StreamingDiarizationTests {
    @Test("Frames are identical whether computed at once or across blocks")
    func frameBuffer() {
        let samples = Signal.voice(seconds: 3, frequency: 150, overtoneDecay: 0.7)
        let whole = LogMelSpectrogram.energiesDB(of: samples)

        var framer = FrameBuffer()
        var streamed: [Float] = []
        var offset = 0
        for size in [1_000, 777, 16_000, 399, 12_345, 100_000] where offset < samples.count {
            let end = min(offset + size, samples.count)
            framer.append(Array(samples[offset..<end]))
            offset = end
            while let slice = framer.nextFrames() {
                streamed += LogMelSpectrogram.energiesDB(of: slice)
            }
        }
        #expect(streamed == whole)
    }

    @Test("Energies match the full spectrogram")
    func energies() {
        let samples = Signal.voice(seconds: 1, frequency: 200, overtoneDecay: 0.6)
        #expect(LogMelSpectrogram.energiesDB(of: samples) == LogMelSpectrogram().frames(of: samples).map(\.energyDB))
    }

    @Test("Streaming a file gives the same speakers as loading it")
    func fileEquivalence() async throws {
        let voiceA = Signal.voice(seconds: 4, frequency: 110, overtoneDecay: 0.85)
        let voiceB = Signal.voice(seconds: 4, frequency: 240, overtoneDecay: 0.45)
        let pause = Signal.silence(seconds: 0.5)
        var samples: [Float] = []
        for _ in 0..<3 { samples += voiceA + pause + voiceB + pause }
        samples = zip(samples, Signal.noise(seconds: Double(samples.count) / Signal.sampleRate + 1, amplitude: 0.003)).map(+)

        let url = try StorageLocations.temporary().audioURL(fileName: "speakers.\(AudioFormat.recordingFileExtension)")
        do {
            let file = try AVAudioFile(forWriting: url, settings: AudioFormat.recordingFileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
            for chunk in Signal.chunks(of: samples, size: 4_096) {
                try file.write(from: try #require(AVAudioPCMBuffer.mono(chunk.samples)))
            }
        }

        let diarizer = SpeakerDiarizer()
        let loaded = diarizer.turns(for: try SpeakerDiarizer.readMonoSamples(from: url))
        let streamed = try await diarizer.turns(forAudioAt: url)
        #expect(streamed == loaded)
        #expect(Set(streamed.map(\.speaker)) == [0, 1])
    }
}

// MARK: - Settings

@Suite("Settings for long recordings and the Mac")
@MainActor
struct LongRecordingSettingsTests {
    @Test("Summarizing while recording and the app presence are remembered")
    func persistence() throws {
        let suiteName = "NotifyAITests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.general.appPresence == .dockAndMenuBar)
        #if os(macOS)
        #expect(settings.analysis.summarizeWhileRecording)
        #endif

        settings.general.appPresence = .menuBar
        settings.analysis.summarizeWhileRecording = false
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.general.appPresence == .menuBar)
        #expect(!reloaded.analysis.summarizeWhileRecording)
        #expect(GeneralSettings.storedAppPresence(defaults: defaults) == .menuBar)
    }

    @Test("Each presence shows the app in at least one place")
    func presence() {
        for presence in AppPresence.allCases {
            #expect(presence.showsDockIcon || presence.showsMenuBarItem)
        }
        #expect(!AppPresence.menuBar.showsDockIcon)
        #expect(!AppPresence.dock.showsMenuBarItem)
    }
}
