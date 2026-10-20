//
//  SpeakerRecognitionTests.swift
//  NotifyAITests
//
//  Who spoke which word, recognized voices, and the user's corrections: naming a speaker,
//  remembering the voice, recognizing it in the next recording. With a scripted diarizer, so
//  no model is needed (the real models are covered by NeuralModelIntegrationTests).
//

import Foundation
@testable import NotifyAI
import NotifyAICore
@testable import NotifyAIPersistence
@testable import NotifyAIServices
import Testing

/// Returns a fixed diarization.
struct ScriptedDiarizer: SpeakerDiarizing {
    let diarization: Diarization

    func diarize(audioAt url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Diarization {
        progress(1)
        return diarization
    }
}

/// A unit vector along `axis` with a little of `blend` mixed in: prints that are similar to
/// each other when they share the axis.
func voicePrint(_ axis: Int, blend: Int? = nil, amount: Float = 0.2) -> [Float] {
    var vector = [Float](repeating: 0, count: 8)
    vector[axis] = 1
    if let blend { vector[blend] = amount }
    return VoicePrint.normalized(vector) ?? vector
}

/// A segment whose words are one second long each, starting at `start`.
func segment(_ text: String, at start: TimeInterval) -> TranscriptSegment {
    let words = text.split(separator: " ").enumerated().map { index, word in
        TranscriptWord(text: (index == 0 ? "" : " ") + word, start: start + Double(index), end: start + Double(index) + 0.9)
    }
    return TranscriptSegment(start: start, end: start + Double(words.count), text: text, words: words)
}

@Suite("Speaker attribution")
struct SpeakerAttributionTests {
    @Test("Detected voices are numbered by first appearance and split segments mid-phrase")
    func numbersVoices() {
        // Voice 1 speaks first, then voice 0 answers inside the same phrase.
        let diarization = Diarization(
            turns: [SpeakerTurn(start: 0, end: 3, speaker: 1), SpeakerTurn(start: 3, end: 6, speaker: 0)],
            voicePrints: [0: voicePrint(0), 1: voicePrint(1)]
        )
        let result = SpeakerAttribution.attribute(
            [segment("eins zwei drei vier fünf sechs", at: 0)],
            evidence: .init(diarization: diarization)
        )
        #expect(result.segments.map(\.speaker) == ["Sprecher 1", "Sprecher 2"])
        #expect(result.segments.map(\.text) == ["eins zwei drei", "vier fünf sechs"])
        #expect(result.segments[0].start == 0)
        #expect(result.segments[1].start == 3)
        #expect(result.speakers.map(\.label) == ["Sprecher 1", "Sprecher 2"])
        #expect(result.speakers[0].voicePrint == voicePrint(1))
        #expect(result.speakers.allSatisfy { $0.origin == .detected })
    }

    @Test("A single unknown voice gets no label, a single recognized one its name")
    func singleVoice() {
        let diarization = Diarization(turns: [SpeakerTurn(start: 0, end: 4, speaker: 0)], voicePrints: [0: voicePrint(0)])
        let segments = [segment("ein Vortrag ohne Pause", at: 0)]
        let unknown = SpeakerAttribution.attribute(segments, evidence: .init(diarization: diarization))
        #expect(unknown.segments.map(\.speaker) == [nil])
        #expect(unknown.speakers.isEmpty)

        let match = VoiceRecognition.Match(profileID: UUID(), name: "Prof. Weber", similarity: 0.9, isUser: false)
        let known = SpeakerAttribution.attribute(segments, evidence: .init(diarization: diarization, matches: [0: match]))
        #expect(known.segments.map(\.speaker) == ["Prof. Weber"])
        #expect(known.speakers.first?.origin == .recognized)
        #expect(known.speakers.first?.profileID == match.profileID)
    }

    @Test("Recognized voices keep their names; unknown ones are numbered without gaps")
    func recognizedNames() {
        let anna = VoiceRecognition.Match(profileID: UUID(), name: "Anna", similarity: 0.8, isUser: false)
        let user = VoiceRecognition.Match(profileID: UUID(), name: "Ich", similarity: 0.9, isUser: true)
        let diarization = Diarization(
            turns: [
                SpeakerTurn(start: 0, end: 2, speaker: 0),
                SpeakerTurn(start: 2, end: 4, speaker: 1),
                SpeakerTurn(start: 4, end: 6, speaker: 2),
            ],
            voicePrints: [0: voicePrint(0), 1: voicePrint(1), 2: voicePrint(2)]
        )
        let result = SpeakerAttribution.attribute(
            [segment("a b", at: 0), segment("c d", at: 2), segment("e f", at: 4)],
            evidence: .init(diarization: diarization, matches: [0: anna, 2: user])
        )
        #expect(result.segments.map(\.speaker) == ["Anna", "Sprecher 1", "Ich"])
    }

    @Test("With microphone and system audio, the other side is told apart by voice")
    func combinesSourceAndVoices() {
        // 0–2 s the microphone (the user), 2–6 s the system audio: two remote voices.
        let activity = SourceActivity(
            microphoneLevels: Array(repeating: -20, count: 20) + Array(repeating: -60, count: 40),
            systemLevels: Array(repeating: -100, count: 20) + Array(repeating: -20, count: 40)
        )
        let diarization = Diarization(
            turns: [
                // The user's voice, and two remote voices.
                SpeakerTurn(start: 0, end: 2, speaker: 0),
                SpeakerTurn(start: 2, end: 4, speaker: 1),
                SpeakerTurn(start: 4, end: 6, speaker: 2),
            ],
            voicePrints: [0: voicePrint(0), 1: voicePrint(1), 2: voicePrint(2)]
        )
        let result = SpeakerAttribution.attribute(
            [segment("hallo zusammen", at: 0), segment("hallo du", at: 2), segment("guten tag", at: 4)],
            evidence: .init(diarization: diarization, activity: activity)
        )
        #expect(result.segments.map(\.speaker) == ["Ich", "Sprecher 1", "Sprecher 2"])
        let user = result.speakers.first { $0.label == "Ich" }
        #expect(user?.origin == .audioSource)
        // The user's own voice print comes along, so "Das bin ich" can remember it.
        #expect(user?.voicePrint == voicePrint(0))
    }

    @Test("Without detected voices the audio source alone labels Ich / Andere")
    func sourceOnly() {
        let activity = SourceActivity(
            microphoneLevels: Array(repeating: -20, count: 20) + Array(repeating: -60, count: 20),
            systemLevels: Array(repeating: -100, count: 20) + Array(repeating: -20, count: 20)
        )
        let result = SpeakerAttribution.attribute(
            [segment("hallo zusammen", at: 0), segment("hallo du", at: 2)],
            evidence: .init(activity: activity, othersLabel: "Ben")
        )
        #expect(result.segments.map(\.speaker) == ["Ich", "Ben"])
        #expect(result.speakers.map(\.origin) == [.audioSource, .audioSource])
        #expect(result.speakers.allSatisfy { $0.voicePrint == nil })
    }
}

@Suite("Voice recognition")
struct VoiceRecognitionTests {
    let anna = VoiceRecognition.Profile(id: UUID(), name: "Anna", voicePrint: voicePrint(0), isUser: false)
    let ben = VoiceRecognition.Profile(id: UUID(), name: "Ben", voicePrint: voicePrint(1), isUser: false)

    @Test("Each voice gets the most similar profile above the threshold, each profile once")
    func oneToOne() {
        let prints = [
            0: voicePrint(0, blend: 1, amount: 0.3),
            // Also resembles Anna, but less than voice 0: two people, not two Annas.
            1: voicePrint(0, blend: 2, amount: 0.6),
            2: voicePrint(1),
        ]
        let matches = VoiceRecognition().match(prints, speech: [0: 10, 1: 10, 2: 10], profiles: [anna, ben])
        #expect(matches[0]?.name == "Anna")
        #expect(matches[1] == nil)
        #expect(matches[2]?.name == "Ben")
    }

    @Test("Different voices and too little speech are not recognized")
    func threshold() {
        let matches = VoiceRecognition().match([0: voicePrint(5), 1: voicePrint(0)], speech: [0: 10, 1: 1], profiles: [anna, ben])
        #expect(matches.isEmpty)
    }

    @Test("Learning a voice moves the print towards the new sample and keeps it normalized")
    func merging() {
        let merged = VoiceRecognition.merged(voicePrint(0), existingWeight: 10, with: voicePrint(1), weight: 10)
        #expect(abs(merged[0] - merged[1]) < 1e-5)
        #expect(abs(VoicePrint.similarity(merged, merged) - 1) < 1e-5)
    }
}

@Suite("Neural diarization result")
struct NeuralDiarizationResultTests {
    @Test("Speakers are numbered by appearance, noise is dropped, prints are weighted by speech")
    func conversion() throws {
        typealias Segment = NeuralSpeakerDiarizer.DiarizedSegment
        let segments = [
            Segment(speakerID: "S2", start: 0, end: 4, embedding: [1, 0]),
            Segment(speakerID: "S1", start: 4, end: 6, embedding: [0, 1]),
            // A short pause within the same speaker: one turn.
            Segment(speakerID: "S1", start: 6.3, end: 8, embedding: [0, 1]),
            // A cough: under a second in total.
            Segment(speakerID: "S3", start: 8, end: 8.5, embedding: [1, 1]),
            Segment(speakerID: "S2", start: 9, end: 10, embedding: [0.6, 0.8]),
        ]
        let diarization = NeuralSpeakerDiarizer.diarization(from: segments)
        #expect(diarization.turns == [
            SpeakerTurn(start: 0, end: 4, speaker: 0),
            SpeakerTurn(start: 4, end: 8, speaker: 1),
            SpeakerTurn(start: 9, end: 10, speaker: 0),
        ])
        let first = try #require(diarization.voicePrints[0])
        // 4 s of [1, 0] and 1 s of [0.6, 0.8], normalized.
        let expected = try #require(VoicePrint.normalized([4.6, 0.8]))
        #expect(abs(first[0] - expected[0]) < 1e-5 && abs(first[1] - expected[1]) < 1e-5)
        #expect(diarization.voicePrints[2] == nil)
    }
}

@Suite("Parakeet segments")
struct ParakeetSegmentTests {
    private func word(_ text: String, _ start: TimeInterval) -> ParakeetEngine.TimedWord {
        ParakeetEngine.TimedWord(text: text, start: start, end: start + 0.3)
    }

    @Test("Words become sentences on the recording timeline")
    func sentences() {
        let words = [word("Guten", 0.0), word("Morgen.", 0.4), word("Wie", 1.2), word("geht's?", 1.5)]
        let segments = ParakeetEngine.segments(text: "", words: words, offset: 10, duration: 3)
        #expect(segments.map(\.text) == ["Guten Morgen.", "Wie geht's?"])
        #expect(segments[0].words.map(\.text) == ["Guten", " Morgen."])
        #expect(segments[0].start == 10)
        #expect(segments[1].start == 11.2)
        #expect(segments.allSatisfy { $0.words.map(\.text).joined() == $0.text })
    }

    @Test("Without token timings the chunk becomes one segment")
    func withoutTimings() {
        let segments = ParakeetEngine.segments(text: " Hallo Welt ", words: [], offset: 5, duration: 2)
        #expect(segments.count == 1)
        #expect(segments.first?.text == "Hallo Welt")
        #expect(segments.first?.end == 7)
    }
}

@Suite("Naming speakers")
@MainActor
struct SpeakerNamingTests {
    let store: NoteStore
    let directory: SpeakerDirectory

    init() throws {
        let locations = try StorageLocations.temporary()
        store = try NoteStore(locations: locations, inMemory: true)
        // A store whose ready marker exists: voices can be remembered.
        let models = NeuralModelStore(downloadBase: locations.neuralModelsDirectory)
        try FileManager.default.createDirectory(at: models.downloadFolder(for: .speakers), withIntermediateDirectories: true)
        try models.markReady(.speakers)
        directory = SpeakerDirectory(store: store, detection: SpeakerDetection(neural: NeuralSpeakerDiarizer(store: models)))
    }

    /// A ready note whose transcript has two detected speakers.
    private func makeNote() throws -> Note {
        let note = Note(title: "Weekly", isTitleUserDefined: true, kind: .recording, status: .ready, participants: ["Anna"])
        let segments = [
            TranscriptSegment(start: 0, end: 4, text: "Hallo zusammen.", speaker: "Sprecher 1"),
            TranscriptSegment(start: 4, end: 6, text: "Hallo Anna.", speaker: "Sprecher 2"),
            TranscriptSegment(start: 6, end: 10, text: "Wir fangen an.", speaker: "Sprecher 1"),
        ]
        note.setTranscript(encoded: try Transcript.encode(segments), plainText: Transcript.plainText(of: segments), engine: .whisper)
        note.speakers = [
            NoteSpeaker(label: "Sprecher 1", origin: .detected, voicePrint: voicePrint(0), speechDuration: 8),
            NoteSpeaker(label: "Sprecher 2", origin: .detected, voicePrint: voicePrint(1), speechDuration: 2),
        ]
        try store.insert(note)
        return note
    }

    private var profiles: [VoiceProfile] { VoiceProfiles(store: store).all() }

    @Test("Naming a speaker renames it everywhere and remembers the voice")
    func renameAndRemember() async throws {
        let note = try makeNote()
        try await directory.rename("Sprecher 1", to: "Anna", in: note, remembersVoice: true)

        #expect(note.decodedTranscript().map(\.speaker) == ["Anna", "Sprecher 2", "Anna"])
        #expect(note.bodyText.hasPrefix("Anna: Hallo zusammen."))
        #expect(note.speakers.map(\.label) == ["Anna", "Sprecher 2"])
        #expect(note.speakers.first?.origin == .named)
        #expect(note.transcriptEditedAt != nil)
        let anna = try #require(profiles.first)
        #expect(anna.name == "Anna")
        #expect(anna.voicePrint == voicePrint(0))
        #expect(note.speakers.first?.profileID == anna.id)

        // Naming the same speaker again does not learn the same recording twice.
        try await directory.rename("Anna", to: "Anna", in: note, remembersVoice: true)
        #expect(profiles.first?.sampleCount == 1)
    }

    @Test("Without remembering, no profile is created")
    func renameOnly() async throws {
        let note = try makeNote()
        try await directory.rename("Sprecher 2", to: "Ben", in: note, remembersVoice: false)
        #expect(note.decodedTranscript().map(\.speaker) == ["Sprecher 1", "Ben", "Sprecher 1"])
        #expect(profiles.isEmpty)
    }

    @Test("Renaming to an existing speaker merges both")
    func merge() async throws {
        let note = try makeNote()
        try await directory.rename("Sprecher 2", to: "Sprecher 1", in: note, remembersVoice: false)
        #expect(Set(note.decodedTranscript().compactMap(\.speaker)) == ["Sprecher 1"])
        #expect(note.speakers.count == 1)
        #expect(note.speakers.first?.speechDuration == 10)
    }

    @Test("„Das bin ich“ labels the speaker as Ich and remembers the user's voice")
    func markAsUser() async throws {
        let note = try makeNote()
        try await directory.rename("Sprecher 2", to: directory.userLabel, in: note, remembersVoice: true)
        #expect(note.decodedTranscript()[1].speaker == "Ich")
        let user = try #require(VoiceProfiles(store: store).user())
        #expect(user.isUser)
        #expect(user.voicePrint == voicePrint(1))
    }

    @Test("One segment can get another speaker; unused speakers disappear")
    func assignSegment() async throws {
        let note = try makeNote()
        let segmentID = note.decodedTranscript()[1].id
        try await directory.assign(segmentID: segmentID, to: "Sprecher 1", in: note)
        #expect(note.decodedTranscript().map(\.speaker) == ["Sprecher 1", "Sprecher 1", "Sprecher 1"])
        #expect(note.speakers.map(\.label) == ["Sprecher 1"])
        try await directory.assign(segmentID: segmentID, to: "Clara", in: note)
        #expect(note.speakers.map(\.label) == ["Sprecher 1", "Clara"])
        #expect(note.speakers.last?.origin == .named)
    }

    @Test("A named voice is recognized in the next recording, corrections are kept")
    func recognitionInNextRecording() async throws {
        let first = try makeNote()
        try await directory.rename("Sprecher 1", to: "Anna", in: first, remembersVoice: true)

        let settings = makeIsolatedSettings()
        settings.analysis.speakerDetection = true
        let diarization = Diarization(
            turns: [SpeakerTurn(start: 0, end: 5, speaker: 0), SpeakerTurn(start: 5, end: 10, speaker: 1)],
            voicePrints: [0: voicePrint(2), 1: voicePrint(0, blend: 3, amount: 0.3)]
        )
        let step = SpeakerStep(settings: settings.analysis, diarizer: ScriptedDiarizer(diarization: diarization), profiles: VoiceProfiles(store: store))
        let second = Note(title: "Next", isTitleUserDefined: true, kind: .recording, status: .queued)
        second.audioFileName = NoteStore.recordingFileName(for: second.id)
        let segments = [segment("eins zwei drei vier fünf", at: 0), segment("sechs sieben acht neun zehn", at: 5)]
        second.setTranscript(encoded: try Transcript.encode(segments), plainText: "", engine: .whisper)
        try store.insert(second)

        #expect(step.needsToRun(for: second, options: ProcessingOptions()))
        let context = ProcessingContext(store: store, noteID: second.id, setStage: { _, _ in }, progress: { _ in })
        try await step.run(second, context: context)
        #expect(second.decodedTranscript().map(\.speaker) == ["Sprecher 1", "Anna"])
        #expect(second.speakers.last?.origin == .recognized)

        // After a correction the step does not run again (until the note is transcribed anew).
        try await directory.rename("Sprecher 1", to: "Ben", in: second, remembersVoice: false)
        #expect(!step.needsToRun(for: second, options: ProcessingOptions()))
        #expect(step.needsToRun(for: second, options: ProcessingOptions(forceTranscription: true)))
    }
}
