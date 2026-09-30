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
import NotifyAICore
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
            guard let file = try? AVAudioFile(forWriting: url, settings: AudioFormat.recordingFileSettings, commonFormat: .pcmFormatFloat32, interleaved: false) else {
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
            let fingerprints = notes.map(IndexableNote.fingerprint(of:))
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

    /// Refreshing the task overview over 500 summaries when nothing changed (the common case
    /// after every save).
    @MainActor
    func testTaskBoardRefreshOf500Summaries() throws {
        let store = try NoteStore(locations: try StorageLocations.temporary(), inMemory: true)
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
        let board = TaskBoard(store: store)
        board.refresh()
        XCTAssertEqual(board.entries.count, 2_000)

        measure(metrics: [XCTClockMetric()]) {
            board.refresh()
        }
    }
}
