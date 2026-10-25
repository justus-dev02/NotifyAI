//
//  PerformanceBenchmarks.swift
//  NotifyAITests
//
//  Benchmarks for the paths that decide energy use and responsiveness. Xcode records
//  baselines per machine (Test navigator → a benchmark → "Set Baseline"); a later change that
//  makes one of them slower then fails the test. The numbers measured for docs/Performance.md
//  come from these tests.
//

@testable import AudioCapture
import AVFoundation
@testable import NotifyAI
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
import SwiftData
import XCTest

final class PerformanceBenchmarks: XCTestCase {
    private static let deviceRate = 48_000.0

    private func aggregateLayout() -> AggregateInputLayout {
        AggregateInputLayout(
            microphone: .init(bufferIndex: 0, streamFormat: DeviceSignal.streamFormat(rate: Self.deviceRate, channels: 1)),
            system: .init(bufferIndex: 1, streamFormat: DeviceSignal.streamFormat(rate: Self.deviceRate, channels: 2))
        )
    }

    /// What the real-time I/O thread does per device cycle (512 frames ≈ 10.7 ms): downmix
    /// microphone and tap into the rings. 10,000 cycles ≈ 107 s of audio.
    func testRealtimeCallbackCost() async throws {
        let capture = AudioCaptureContext(tickInterval: .never)
        let (_, levels) = AsyncStream.makeStream(of: AudioLevel.self)
        capture.begin(sink: MemorySink(), chunks: nil, levels: levels, recordsSourceActivity: true)
        let input = try capture.configure(aggregateLayout())

        let cycle = 512
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        var microphone = [Float](repeating: 0.1, count: cycle)
        var system = [Float](repeating: 0.1, count: cycle * 2)

        measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) {
            microphone.withUnsafeMutableBytes { microphoneBytes in
                system.withUnsafeMutableBytes { systemBytes in
                    list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(microphoneBytes.count), mData: microphoneBytes.baseAddress)
                    list[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(systemBytes.count), mData: systemBytes.baseAddress)
                    for index in 0..<10_000 {
                        input.process(list.unsafePointer)
                        if index % 1_000 == 999 {
                            // Plays the consumer's part without measuring it.
                            input.microphone?.ring.skipAvailable()
                            input.system.ring.skipAvailable()
                        }
                    }
                }
            }
        }
        await capture.finish()
    }

    /// The processing queue's work for 60 s of microphone + system audio: resample both
    /// sources, mix, measure levels and source activity, encode AAC and write the CAF file.
    func testProcessingOneMinuteOfMeetingAudio() throws {
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]) {
            let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).caf")
            defer { try? FileManager.default.removeItem(at: url) }
            guard let file = try? AVAudioFile(
                forWriting: url,
                settings: AudioFormat.recordingFileSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            ) else {
                return XCTFail("Could not create the file")
            }
            let capture = AudioCaptureContext(tickInterval: .never)
            let (_, levels) = AsyncStream.makeStream(of: AudioLevel.self, bufferingPolicy: .bufferingNewest(1))
            capture.begin(sink: file, chunks: nil, levels: levels, recordsSourceActivity: true)
            guard let input = try? capture.configure(aggregateLayout()) else { return XCTFail("Could not configure") }
            for _ in 0..<60 {
                DeviceSignal.feed(input, seconds: 1, rate: Self.deviceRate)
                capture.processPendingAudio()
            }
            let result = capture.finishBlocking()
            // The feed sends whole cycles of 512 frames: 94 per second instead of 93.75.
            let fedSeconds = 60 * (Self.deviceRate / 512).rounded(.up) * 512 / Self.deviceRate
            XCTAssertEqual(result.duration, fedSeconds, accuracy: 0.02)
        }
    }

    /// Checking 500 unchanged notes for re-indexing. The fingerprint reads only the note row;
    /// the texts (100 KB each, 50 MB in total) are never loaded.
    @MainActor
    func testIndexFingerprintOf500Notes() throws {
        let locations = try StorageLocations.temporary()
        do {
            let store = try NoteStore(locations: locations)
            let text = String(repeating: "Das Budget der Herbstkampagne wurde besprochen. ", count: 2_100)
            for index in 0..<500 {
                store.context.insert(Note(title: "Notiz \(index)", isTitleUserDefined: true, kind: .document, status: .ready, bodyText: text))
            }
            try store.save()
        }
        let store = try NoteStore(locations: locations)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            // A fresh context, as after a launch: nothing is cached.
            let context = ModelContext(store.container)
            let notes = (try? context.fetch(FetchDescriptor<Note>())) ?? []
            let fingerprints = notes.map { IndexableNote.fingerprint(of: $0, embeddingSpace: "space") }
            XCTAssertEqual(Set(fingerprints).count, 500)
        }
    }

    /// For comparison: the same check when every note's text has to be read, as the previous
    /// fingerprint (text length and prefix) did.
    @MainActor
    func testReadingTheTextOf500NotesForComparison() throws {
        let locations = try StorageLocations.temporary()
        do {
            let store = try NoteStore(locations: locations)
            let text = String(repeating: "Das Budget der Herbstkampagne wurde besprochen. ", count: 2_100)
            for index in 0..<500 {
                store.context.insert(Note(title: "Notiz \(index)", isTitleUserDefined: true, kind: .document, status: .ready, bodyText: text))
            }
            try store.save()
        }
        let store = try NoteStore(locations: locations)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let context = ModelContext(store.container)
            let notes = (try? context.fetch(FetchDescriptor<Note>())) ?? []
            let total = notes.reduce(0) { $0 + $1.bodyText.utf8.count }
            XCTAssertGreaterThan(total, 0)
        }
    }

    /// Refreshing the task overview over 500 summaries with 2 000 tasks: one query over the
    /// task rows, no summary is decoded.
    @MainActor
    func testTaskBoardRefreshOf500Summaries() throws {
        let services = try ServiceContainer(
            settings: makeIsolatedSettings(),
            locations: try StorageLocations.temporary(),
            inMemory: true,
            recordingActivity: nil
        )
        let store = services.store
        for index in 0..<500 {
            let note = Note(title: "Meeting \(index)", isTitleUserDefined: true, kind: .recording, status: .ready)
            note.summary = NoteSummary(
                overview: "Überblick \(index)",
                actionItems: (0..<4).map { ActionItem(task: "Aufgabe \($0) aus \(index)", owner: $0.isMultiple(of: 2) ? "Anna" : "Ben", due: "Freitag") },
                source: .extractive
            )
            store.context.insert(note)
        }
        try store.save()
        let board = services.tasks
        board.refresh()
        XCTAssertEqual(board.entries.count, 2_000)

        measure(metrics: [XCTClockMetric()]) {
            board.refresh()
        }
    }

    // MARK: Search index at scale

    /// A library of 2,000 notes with 40 passages each (80,000 passages, about 20 minutes of
    /// conversation per note) as the search keeps it: text, term frequencies and three
    /// 512-dimensional vectors per passage, one per window of about 25 words.
    private static let largeIndexNotes = 2_000
    private static let passagesPerNote = 40

    /// Loading the whole index from disk, as at every launch: time and peak memory.
    @MainActor
    func testLoadingSearchIndexOf2000Notes() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Index-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnowledgeIndexStore(directory: directory)
        for note in SyntheticIndex.notes(count: Self.largeIndexNotes, passagesPerNote: Self.passagesPerNote) {
            await store.save(note)
        }

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let index = Self.blocking { await store.load() }
            XCTAssertEqual(index.notes.count, Self.largeIndexNotes)
        }

        // What the loaded index keeps on the heap; the memory metric above also counts what
        // decoding allocates and frees.
        let before = Self.heapInUse()
        let index = Self.blocking { await store.load() }
        let retained = Self.heapInUse() - before
        XCTContext.runActivity(named: "Search index of \(index.notes.count) notes: \(retained / 1_000_000) MB on the heap") { _ in }
        withExtendedLifetime(index) {}
    }

    private static func heapInUse() -> Int {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return statistics.size_in_use
    }

    /// One question over all 80,000 passages: full-text and semantic ranking, fusion.
    func testSearchingIndexOf2000Notes() {
        let notes = SyntheticIndex.notes(count: Self.largeIndexNotes, passagesPerNote: Self.passagesPerNote)
        let index = KnowledgeIndex(notes: Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) }))
        // Random words and vectors answer nothing; without thresholds every passage is scored,
        // sorted and considered, the most work a question can cause.
        let retriever = HybridRetriever(
            index: index, embedder: SyntheticIndex.Embedder(), tuning: HybridRetriever.Tuning(threshold: 0, fullTextThreshold: 0)
        )

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let result = retriever.search(SearchRequest(text: "budget kampagne agentur", languageCode: "de"))
            XCTAssertFalse(result.passages.isEmpty)
        }
    }

    /// Indexing one hour of conversation (about 9,000 words in 600 segments) with the
    /// contextual model: one vector per window of about 25 words. Runs in the background
    /// after processing; skipped where the model is not installed.
    func testIndexingOneHourWithMeaningVectors() throws {
        let embedder = ContextualSentenceEmbedder()
        try XCTSkipUnless(embedder.modelStatus(for: "de") == .installed, "The contextual embedding model is not installed")
        let sentences = [
            "Wir müssen das Budget für die Herbstkampagne noch einmal prüfen.",
            "Die Agentur schickt die neuen Motive bis Mittwoch.",
            "Beim Login hängt die Seite manchmal nach dem Passwort.",
        ]
        let segments = (0..<600).map { index in
            TranscriptSegment(start: Double(index) * 6, end: Double(index) * 6 + 5, text: sentences[index % 3] + " Punkt \(index).")
        }
        let note = IndexableNote(title: "Lange Besprechung", bodyText: segments.map(\.text).joined(separator: " "), segments: segments)
        let builder = KnowledgeIndexBuilder(embedder: embedder)
        _ = embedder.vector(for: "Laden", languageCode: "de")

        measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) {
            let entry = builder.entry(for: note)
            XCTAssertGreaterThan(entry.passageVectors.count, 300)
        }
    }

    /// Runs async work to completion inside a synchronous `measure` block.
    private static func blocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task {
            box.value = await work()
            done.signal()
        }
        done.wait()
        return box.value!
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }
}

/// Generated index entries of a realistic size; the same seed gives the same index.
private enum SyntheticIndex {
    /// Deterministic random vectors, normalized like real sentence embeddings.
    struct Embedder: SentenceEmbedding {
        func vector(for text: String, languageCode: String) -> EmbeddingVector? {
            var generator = SeededGenerator(seed: UInt64(truncatingIfNeeded: text.hashValue))
            return SyntheticIndex.vector(using: &generator)
        }

        /// Named like the contextual model's spaces, so the search uses the vectors.
        func space(for languageCode: String) -> String? {
            "contextual-synthetic"
        }
    }

    static let dimension = 512

    static func notes(count: Int, passagesPerNote: Int) -> [IndexedNote] {
        var generator = SeededGenerator(seed: 42)
        let vocabulary = (0..<3_000).map { "wort\($0)" } + ["budget", "kampagne", "agentur", "termin", "vertrag"]
        return (0..<count).map { noteIndex in
            let noteID = UUID()
            let words = (0..<passagesPerNote).map { _ in (0..<70).map { _ in vocabulary.randomElement(using: &generator)! } }
            let terms = NoteTerms(terms: words.joined())
            let passages = words.enumerated().map { passageIndex, words in
                IndexedPassage(
                    id: "\(noteID)-\(passageIndex)",
                    noteID: noteID,
                    kind: .transcript,
                    text: words.joined(separator: " "),
                    start: TimeInterval(passageIndex * 30),
                    termFrequencies: terms.frequencies(of: words),
                    termCount: words.count
                )
            }
            // Three windows of about 25 words per 70-word passage, as the builder makes them.
            let windows = passages.indices.flatMap { passage in
                (0..<3).compactMap { _ in vector(using: &generator).map { (passage: passage, vector: $0) } }
            }
            return IndexedNote(
                id: noteID,
                contentHash: UUID().uuidString,
                title: "Meeting \(noteIndex)",
                createdAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(noteIndex) * 86_400),
                kind: .recording,
                focus: .general,
                languageCode: "de",
                isFavorite: false,
                participants: ["Anna", "Ben"],
                labels: [],
                entities: NamedEntities(),
                keywords: [],
                topics: [],
                vector: EmbeddingVector.mean(of: windows.map(\.vector)),
                embeddingSpace: "contextual-synthetic",
                passageVectors: PassageVectors(windows),
                terms: terms,
                passages: passages
            )
        }
    }

    static func vector(using generator: inout some RandomNumberGenerator) -> EmbeddingVector? {
        let values = (0..<dimension).map { _ in Float.random(in: -1...1, using: &generator) }
        return EmbeddingVector.normalized(values).map(EmbeddingVector.init)
    }
}
