//
//  SystemAudioTests.swift
//  NotifyAITests
//

@testable import AudioCapture
import AVFoundation
import Foundation
@testable import NotifyAI
import NotifyAICore
import SwiftData
import Testing

// MARK: - Source activity

@Suite("Source activity")
struct SourceActivityTests {
    @Test("Levels are collected per 100 ms bin on the recording timeline")
    func recorderBins() {
        var recorder = SourceActivityRecorder()
        let microphone = Signal.voice(seconds: 0.25, frequency: 150, overtoneDecay: 0.7)
        let system = [Float](repeating: 0, count: microphone.count)
        // Two blocks of different size must land in the same bins as one block.
        recorder.append(microphone: microphone[..<1_000], system: system[..<1_000], startFrame: 0)
        recorder.append(microphone: microphone[1_000...], system: system[1_000...], startFrame: 1_000)

        let activity = recorder.makeActivity()
        #expect(activity.binCount == 3)
        #expect(activity.microphoneLevels.allSatisfy { $0 > -40 })
        #expect(activity.systemLevels.allSatisfy { $0 == -100 })
    }

    @Test("Levels survive encoding and are clamped to the stored range")
    func encoding() throws {
        let activity = SourceActivity(microphoneLevels: [-20, -150, 30], systemLevels: [-100, -60.4, .nan])
        let decoded = try JSONDecoder().decode(SourceActivity.self, from: JSONEncoder().encode(activity))
        #expect(decoded == activity)
        #expect(decoded.microphoneLevels == [-20, -100, 30])
        #expect(decoded.systemLevels == [-100, -60, -100])
    }

    @Test("Bins of a time range are clamped to the recording")
    func binRange() {
        let activity = SourceActivity(microphoneLevels: Array(repeating: -20, count: 10), systemLevels: Array(repeating: -100, count: 10))
        #expect(activity.bins(from: 0.25, to: 0.51) == 2..<6)
        #expect(activity.bins(from: 0.9, to: 5) == 9..<10)
        #expect(activity.bins(from: 3, to: 4).isEmpty)
    }
}

// MARK: - Speaker attribution

@Suite("Speaker attribution by audio source")
struct SourceSpeakerAttributionTests {
    /// 2 s user (microphone), then 2 s others (system audio, leaking into the microphone
    /// at a lower level as it does with loudspeakers).
    private let activity = SourceActivity(
        microphoneLevels: Array(repeating: -20, count: 20) + Array(repeating: -35, count: 20),
        systemLevels: Array(repeating: -100, count: 20) + Array(repeating: -20, count: 20)
    )

    private func words(_ texts: [String], from start: TimeInterval, step: TimeInterval) -> [TranscriptWord] {
        texts.enumerated().map { index, text in
            let wordStart = start + Double(index) * step
            return TranscriptWord(text: (index == 0 ? "" : " ") + text, start: wordStart, end: wordStart + step * 0.8)
        }
    }

    @Test("Loudspeaker echo in the microphone does not turn the others into the user")
    func classification() {
        let speakers = SourceSpeakerAttribution.classify(activity)
        #expect(speakers.prefix(20).allSatisfy { $0 == .user })
        #expect(speakers.suffix(20).allSatisfy { $0 == .others })
    }

    @Test("A segment spanning both speakers is split at the change")
    func splitsSegment() {
        let texts = ["Ich", "stelle", "kurz", "vor.", "Danke,", "wir", "haben", "Fragen."]
        let segment = TranscriptSegment(start: 0, end: 4, text: texts.joined(separator: " "), words: words(texts, from: 0.1, step: 0.5))

        let result = SourceSpeakerAttribution.assign(activity, to: [segment])

        #expect(result.count == 2)
        #expect(result[0].id == segment.id)
        #expect(result[0].speaker == "Ich")
        #expect(result[0].text == "Ich stelle kurz vor.")
        #expect(result[0].start == 0)
        #expect(result[1].speaker == "Andere")
        #expect(result[1].text == "Danke, wir haben Fragen.")
        #expect(result[1].end == 4)
    }

    @Test("Segments without word timing get the majority speaker")
    func segmentWithoutWords() {
        let segments = [
            TranscriptSegment(start: 0.2, end: 1.8, text: "Hallo."),
            TranscriptSegment(start: 1.9, end: 3.9, text: "Hallo zurück."),
        ]
        let result = SourceSpeakerAttribution.assign(activity, to: segments, othersLabel: "Anna")
        #expect(result.map(\.speaker) == ["Ich", "Anna"])
    }

    @Test("A single misclassified short word is merged into its surroundings")
    func smoothsShortRuns() {
        // User speaks for 4 s; one bin in the middle has a short system sound.
        var system = [Float](repeating: -100, count: 40)
        system[20] = -20
        let activity = SourceActivity(microphoneLevels: Array(repeating: -20, count: 40), systemLevels: system)
        let texts = ["eins", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht"]
        let segment = TranscriptSegment(start: 0, end: 4, text: texts.joined(separator: " "), words: words(texts, from: 0, step: 0.5))

        let result = SourceSpeakerAttribution.assign(activity, to: [segment])
        #expect(result.count == 1)
        #expect(result.first?.speaker == "Ich")
    }

    @Test("Silence keeps the transcript unchanged")
    func silence() {
        let silent = SourceActivity(microphoneLevels: Array(repeating: -100, count: 10), systemLevels: Array(repeating: -100, count: 10))
        let segment = TranscriptSegment(start: 0, end: 1, text: "Etwas.")
        #expect(SourceSpeakerAttribution.assign(silent, to: [segment]).first?.speaker == nil)
    }

    @Test("One participant names the other side")
    func othersLabel() {
        #expect(SourceSpeakerAttribution.othersLabel(participants: ["Anna"]) == "Anna")
        #expect(SourceSpeakerAttribution.othersLabel(participants: ["Anna", "Ben"]) == "Andere")
        #expect(SourceSpeakerAttribution.othersLabel(participants: []) == "Andere")
    }
}

// MARK: - Process matching

@Suite("Audio process matching")
struct AudioProcessMatcherTests {
    private func process(_ bundleID: String?, path: String? = nil, id: UInt32 = 1) -> AudioProcessInfo {
        AudioProcessInfo(objectID: id, pid: Int32(id), bundleID: bundleID, executablePath: path, isPlayingAudio: false)
    }

    @Test("Helper processes of Chromium and Electron apps belong to the app")
    func helpers() {
        let chrome = "com.google.Chrome"
        #expect(AudioProcessMatcher.belongs(process("com.google.Chrome.helper"), toAppWithBundleID: chrome, bundlePath: nil))
        #expect(AudioProcessMatcher.belongs(process(chrome), toAppWithBundleID: chrome, bundlePath: nil))
        #expect(!AudioProcessMatcher.belongs(process("com.google.Chromebook"), toAppWithBundleID: chrome, bundlePath: nil))
    }

    @Test("Processes inside the app bundle belong to the app")
    func bundlePath() {
        let helper = process("us.zoom.CptHost", path: "/Applications/zoom.us.app/Contents/Frameworks/cpthost.app/Contents/MacOS/CptHost")
        #expect(AudioProcessMatcher.belongs(helper, toAppWithBundleID: "us.zoom.xos", bundlePath: "/Applications/zoom.us.app"))
        let other = process("com.other", path: "/Applications/zoom.us.app.backup/Other")
        #expect(!AudioProcessMatcher.belongs(other, toAppWithBundleID: "us.zoom.xos", bundlePath: "/Applications/zoom.us.app"))
    }

    @Test("Safari's web audio comes from the WebKit GPU process")
    func safari() {
        let gpu = process("com.apple.WebKit.GPU")
        #expect(AudioProcessMatcher.belongs(gpu, toAppWithBundleID: "com.apple.Safari", bundlePath: nil))
        #expect(!AudioProcessMatcher.belongs(gpu, toAppWithBundleID: "com.hnc.Discord", bundlePath: nil))
    }

    @Test("Only the processes of the chosen app are selected")
    func filtering() {
        let processes = [
            process("com.hnc.Discord", id: 1),
            process("com.hnc.Discord.helper", id: 2),
            process("com.spotify.client", id: 3),
            process(nil, id: 4),
        ]
        let matches = AudioProcessMatcher.processes(ofAppWithBundleID: "com.hnc.Discord", bundlePath: nil, in: processes)
        #expect(matches.map(\.objectID) == [1, 2])
    }
}

// MARK: - Capture

@Suite("Microphone and system audio capture")
struct AggregateCaptureTests {
    private static let deviceRate: Double = 48_000
    private static let cycle = 512

    private static func floatFormat(channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: deviceRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    /// Feeds `seconds` of audio like an aggregate device: microphone (mono) in buffer 0,
    /// tap (stereo, interleaved) in buffer 1. System audio starts after half the time.
    private func feed(_ input: AggregateCaptureInput, seconds: Double) {
        let totalFrames = Int(seconds * Self.deviceRate)
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        var microphone = [Float](repeating: 0, count: Self.cycle)
        var system = [Float](repeating: 0, count: Self.cycle * 2)

        for start in stride(from: 0, to: totalFrames, by: Self.cycle) {
            for frame in 0..<Self.cycle {
                let time = Double(start + frame) / Self.deviceRate
                microphone[frame] = 0.2 * Float(sin(2 * .pi * 220 * time))
                let value: Float = time >= seconds / 2 ? 0.2 * Float(sin(2 * .pi * 330 * time)) : 0
                system[2 * frame] = value
                system[2 * frame + 1] = value
            }
            microphone.withUnsafeMutableBytes { microphoneBytes in
                system.withUnsafeMutableBytes { systemBytes in
                    list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(microphoneBytes.count), mData: microphoneBytes.baseAddress)
                    list[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(systemBytes.count), mData: systemBytes.baseAddress)
                    input.process(list.unsafePointer)
                }
            }
        }
    }

    private func makeFile() throws -> AVAudioFile {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).caf")
        return try AVAudioFile(forWriting: url, settings: AudioFormat.recordingFileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    @Test("Microphone and system audio are mixed on one timeline with separate levels")
    func mixesSources() async throws {
        let capture = AudioCaptureContext()
        let (chunks, chunkContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let (levels, levelContinuation) = AsyncStream.makeStream(of: AudioLevel.self)
        capture.begin(sink: try makeFile(), chunks: chunkContinuation, levels: levelContinuation, recordsSourceActivity: true)
        let input = try capture.configure(AggregateInputLayout(
            microphone: .init(bufferIndex: 0, streamFormat: Self.floatFormat(channels: 1)),
            system: .init(bufferIndex: 1, streamFormat: Self.floatFormat(channels: 2))
        ))

        feed(input, seconds: 2)
        let result = capture.finish()

        #expect(abs(result.duration - 2) < 0.05)
        let activity = try #require(result.sourceActivity)
        #expect(abs(activity.binCount - 20) <= 1)
        // First second: only the microphone. Second second: both.
        #expect(activity.systemLevels.prefix(8).allSatisfy { $0 == -100 })
        #expect(activity.systemLevels[12..<18].allSatisfy { $0 > -25 })
        #expect(activity.microphoneLevels.prefix(18).allSatisfy { $0 > -25 })

        var chunkFrames = 0
        var expectedStart: Int64 = 0
        for await chunk in chunks {
            #expect(chunk.startFrame == expectedStart)
            expectedStart = chunk.endFrame
            chunkFrames += chunk.samples.count
        }
        #expect(chunkFrames == Int((result.duration * AudioFormat.sampleRate).rounded()))

        var last: AudioLevel?
        for await level in levels { last = level }
        #expect(last?.hasReceivedSystemAudio == true)
        #expect(last?.systemRMS != nil)
    }

    @Test("Paused audio is dropped and does not advance the timeline")
    func pause() throws {
        let capture = AudioCaptureContext()
        let (_, chunkContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let (_, levelContinuation) = AsyncStream.makeStream(of: AudioLevel.self)
        capture.begin(sink: try makeFile(), chunks: chunkContinuation, levels: levelContinuation, recordsSourceActivity: false)
        let input = try capture.configure(AggregateInputLayout(microphone: nil, system: .init(bufferIndex: 1, streamFormat: Self.floatFormat(channels: 2))))

        feed(input, seconds: 1)
        capture.setPaused(true)
        feed(input, seconds: 1)
        capture.setPaused(false)
        feed(input, seconds: 0.5)
        let result = capture.finish()

        #expect(abs(result.duration - 1.5) < 0.05)
        #expect(result.sourceActivity == nil)
    }

    @Test("Mixing limits the sum to full scale")
    func mixing() {
        #expect(AudioCaptureContext.mix([0.8, -0.8, 0.1], [0.5, -0.5, 0.2]) == [1, -1, 0.3].map(Float.init))
    }
}

// MARK: - Settings and persistence

@Suite("System audio settings and storage")
@MainActor
struct SystemAudioPersistenceTests {
    @Test("Source and app are remembered")
    func settingsPersist() throws {
        let suiteName = "NotifyAITests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.recording.audioSource == .microphone)
        #expect(settings.recording.systemAudioTarget == .allApps)
        #expect(settings.analysis.speakersFromAudioSource)

        settings.recording.audioSource = .microphoneAndSystemAudio
        settings.recording.systemAudioTarget = .app(bundleID: "us.zoom.xos", name: "zoom.us")
        settings.analysis.speakersFromAudioSource = false

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.recording.audioSource == .microphoneAndSystemAudio)
        #expect(reloaded.recording.systemAudioTarget == .app(bundleID: "us.zoom.xos", name: "zoom.us"))
        #expect(!reloaded.analysis.speakersFromAudioSource)
    }

    @Test("Notes of the first schema open with the microphone as source")
    func migratesFromFirstSchema() throws {
        let locations = try StorageLocations.temporary()
        let noteID = UUID()
        do {
            let schema = Schema(versionedSchema: NotifyAISchemaV1.self)
            let container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, url: locations.databaseURL, cloudKitDatabase: .none)
            )
            let context = ModelContext(container)
            context.insert(NotifyAISchemaV1.Note(id: noteID, title: "Alt", isTitleUserDefined: true, kind: .recording, status: .ready))
            try context.save()
        }

        let store = try NoteStore(locations: locations)
        let note = try #require(store.note(id: noteID))
        #expect(note.title == "Alt")
        #expect(note.audioSource == .microphone)
        #expect(note.audioSourceDescription == nil)
        #expect(note.sourceActivity == nil)
    }

    @Test("Source details are stored on the note")
    func noteAccessors() throws {
        let store = try NoteStore(locations: try StorageLocations.temporary(), inMemory: true)
        let note = Note(title: "Meeting", isTitleUserDefined: true, kind: .recording, status: .ready)
        note.audioSource = .microphoneAndSystemAudio
        note.sourceAppName = "Discord"
        note.sourceActivity = SourceActivity(microphoneLevels: [-20], systemLevels: [-30])
        try store.insert(note)

        let loaded = try #require(store.note(id: note.id))
        #expect(loaded.audioSource == .microphoneAndSystemAudio)
        #expect(loaded.audioSourceDescription == "Mikrofon + Discord")
        #expect(loaded.sourceActivity?.systemLevels == [-30])
    }
}

@Suite("Processing with audio sources")
@MainActor
struct SourceProcessingTests {
    @Test("Microphone + system audio recordings are labelled Ich / Andere")
    func labelsSpeakers() async throws {
        let store = try NoteStore(locations: try StorageLocations.temporary(), inMemory: true)
        let settings = makeIsolatedSettings()
        let segments = [
            TranscriptSegment(start: 0, end: 1.9, text: "Guten Morgen."),
            TranscriptSegment(start: 2.1, end: 3.9, text: "Morgen!"),
        ]
        let engine = MockTranscriptionEngine(kind: .appleSpeech, segments: segments)
        let coordinator = ProcessingCoordinator(
            store: store,
            settings: settings,
            transcription: TranscriptionService(appleSpeech: engine, whisper: engine),
            summarization: SummarizationService(languageModel: MockSummarizer(), fallback: MockSummarizer(), availability: { _ in .available }),
            diarizer: SpeakerDiarizer()
        )

        let note = Note(title: "Call", isTitleUserDefined: true, kind: .recording, status: .queued, participants: ["Ben"])
        let fileName = NoteStore.recordingFileName(for: note.id)
        note.audioFileName = fileName
        try Data([0]).write(to: store.locations.audioURL(fileName: fileName))
        note.audioSource = .microphoneAndSystemAudio
        note.sourceActivity = SourceActivity(
            microphoneLevels: Array(repeating: -20, count: 20) + Array(repeating: -40, count: 20),
            systemLevels: Array(repeating: -100, count: 20) + Array(repeating: -20, count: 20)
        )
        try store.insert(note)

        coordinator.enqueue(.process(note.id))
        for _ in 0..<200 where note.status != .ready && note.status != .failed {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(note.status == .ready)
        #expect(note.decodedTranscript().map(\.speaker) == ["Ich", "Ben"])
        #expect(note.bodyText == "Ich: Guten Morgen.\nBen: Morgen!")
    }
}
