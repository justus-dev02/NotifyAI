//
//  NeuralModelIntegrationTests.swift
//  NotifyAITests
//
//  Speaker detection, voice recognition and Parakeet with the real models. The models are
//  hundreds of megabytes, so these tests only run when a fixture folder is given:
//
//    ln -s /path/to/fixtures ~/Library/Caches/NotifyAINeuralFixtures
//
//  (or the environment variable NOTIFYAI_NEURAL_FIXTURES in the test plan).
//  The folder contains `models/` (downloaded as in the settings, with the ready markers)
//  and recordings spoken by system voices: two meetings `conversationN.caf` with
//  `conversationN.json` (who speaks when), and `dictation.caf` with its text `dictation.txt`
//  in one natural voice (the other German system voices sound too synthetic for any
//  recognizer).
//

import Foundation
@testable import NotifyAI
import NotifyAICore
@testable import NotifyAIServices
import Testing

enum NeuralFixtures {
    static var directory: URL? {
        if let path = ProcessInfo.processInfo.environment["NOTIFYAI_NEURAL_FIXTURES"] {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        // The test host is sandboxed (its own home is the container), but may read any path.
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        let link = URL(filePath: String(cString: home), directoryHint: .isDirectory)
            .appending(path: "Library/Caches/NotifyAINeuralFixtures", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: link.appending(path: "models").path(percentEncoded: false)) else { return nil }
        return link
    }

    static var store: NeuralModelStore? {
        directory.map { NeuralModelStore(downloadBase: $0.appending(path: "models")) }
    }

    struct Line: Decodable {
        let speaker: String
        let start: TimeInterval
        let end: TimeInterval
    }

    static func lines(_ name: String) throws -> [Line] {
        let url = try #require(directory).appending(path: "\(name).json")
        return try JSONDecoder().decode([Line].self, from: Data(contentsOf: url))
    }

    static func audio(_ name: String) throws -> URL {
        try #require(directory).appending(path: "\(name).caf")
    }

    /// The detected voice that speaks most of each true speaker's lines.
    static func mapping(of diarization: Diarization, to lines: [Line]) -> [String: Int] {
        var overlap: [String: [Int: TimeInterval]] = [:]
        for line in lines {
            for turn in diarization.turns where turn.end > line.start && turn.start < line.end {
                overlap[line.speaker, default: [:]][turn.speaker, default: 0] += min(turn.end, line.end) - max(turn.start, line.start)
            }
        }
        return overlap.compactMapValues { $0.max { $0.value < $1.value }?.key }
    }

    /// Share of the spoken time attributed to the right voice.
    static func accuracy(of diarization: Diarization, on lines: [Line]) -> Double {
        let mapping = mapping(of: diarization, to: lines)
        var correct: TimeInterval = 0
        var total: TimeInterval = 0
        for line in lines {
            total += line.end - line.start
            for turn in diarization.turns where turn.speaker == mapping[line.speaker] && turn.end > line.start && turn.start < line.end {
                correct += min(turn.end, line.end) - max(turn.start, line.start)
            }
        }
        return total > 0 ? correct / total : 0
    }
}

@Suite("Neural models (real models)", .enabled(if: NeuralFixtures.directory != nil), .serialized)
struct NeuralModelIntegrationTests {
    @Test("Three voices of a meeting are told apart")
    func diarizesMeeting() async throws {
        let store = try #require(NeuralFixtures.store)
        #expect(store.isInstalled(.speakers))
        let diarizer = NeuralSpeakerDiarizer(store: store)
        let diarization = try await diarizer.diarize(audioAt: try NeuralFixtures.audio("conversation1")) { _ in }
        let lines = try NeuralFixtures.lines("conversation1")

        let voices = Set(diarization.turns.map(\.speaker))
        #expect(voices.count == 3, "Found \(voices.count) voices")
        let mapping = NeuralFixtures.mapping(of: diarization, to: lines)
        #expect(Set(mapping.values).count == 3, "Voices are confused: \(mapping)")
        let accuracy = NeuralFixtures.accuracy(of: diarization, on: lines)
        #expect(accuracy > 0.9, "Only \(accuracy) of the speech attributed correctly")
        #expect(diarization.voicePrints.count == 3)
    }

    @Test("Voices named in one meeting are recognized in the next one")
    func recognizesVoices() async throws {
        let store = try #require(NeuralFixtures.store)
        let diarizer = NeuralSpeakerDiarizer(store: store)
        let first = try await diarizer.diarize(audioAt: try NeuralFixtures.audio("conversation1")) { _ in }
        let mapping = NeuralFixtures.mapping(of: first, to: try NeuralFixtures.lines("conversation1"))
        // The user names the speakers of the first meeting.
        let profiles = try mapping.map { name, voice in
            VoiceRecognition.Profile(id: UUID(), name: name, voicePrint: try #require(first.voicePrints[voice]), isUser: false)
        }

        let second = try await diarizer.diarize(audioAt: try NeuralFixtures.audio("conversation2")) { _ in }
        let truth = NeuralFixtures.mapping(of: second, to: try NeuralFixtures.lines("conversation2"))
        let matches = VoiceRecognition().match(second.voicePrints, speech: second.speechPerVoice, profiles: profiles)

        for (name, voice) in truth {
            #expect(matches[voice]?.name == name, "\(name) recognized as \(matches[voice]?.name ?? "nobody")")
        }
        // Grandpa does not speak in the second meeting; nobody is mistaken for him.
        #expect(!matches.values.contains { $0.name == "Grandpa" })
        // The threshold lies well between the same voice and different voices (measured:
        // same voice 0.85–0.94, different voices 0.06–0.42).
        let threshold = VoiceRecognition().threshold
        for (name, voice) in truth {
            let voicePrint = try #require(second.voicePrints[voice])
            for profile in profiles {
                let similarity = VoicePrint.similarity(voicePrint, profile.voicePrint)
                if profile.name == name {
                    #expect(similarity > threshold + 0.15, "\(name) resembles itself only by \(similarity)")
                } else {
                    #expect(similarity < threshold - 0.05, "\(name) resembles \(profile.name) by \(similarity)")
                }
            }
        }
    }

    @Test("Parakeet transcribes German speech with word timings")
    func parakeetTranscribes() async throws {
        let store = try #require(NeuralFixtures.store)
        #expect(store.isInstalled(.parakeet))
        let engine = ParakeetEngine(store: store)
        let segments = try await engine.transcribeFile(
            at: try NeuralFixtures.audio("dictation"),
            options: TranscriptionOptions(language: .german, whisperModel: .recommended)
        ) { _ in }

        let script = try String(contentsOf: try #require(NeuralFixtures.directory).appending(path: "dictation.txt"), encoding: .utf8)
        let expected = Self.words(script)
        let recognized = Self.words(segments.map(\.text).joined(separator: " "))
        let errorRate = Self.wordErrorRate(expected, recognized)
        #expect(errorRate < 0.15, "Word error rate \(errorRate): \(segments.map { "[\($0.start)-\($0.end)] \($0.text)" }.joined(separator: " | "))")

        // Word timings lie inside their segment and run forward.
        for segment in segments {
            #expect(!segment.words.isEmpty)
            #expect(segment.words.map(\.text).joined().trimmingCharacters(in: .whitespaces) == segment.text)
            let starts = segment.words.map(\.start)
            #expect(starts == starts.sorted())
            #expect((segment.words.first?.start ?? 0) >= segment.start - 0.01)
        }
    }

    // MARK: Helpers

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Levenshtein distance on words, divided by the length of the reference.
    static func wordErrorRate(_ reference: [String], _ hypothesis: [String]) -> Double {
        guard !reference.isEmpty else { return hypothesis.isEmpty ? 0 : 1 }
        var previous = Array(0...hypothesis.count)
        for (row, word) in reference.enumerated() {
            var current = [row + 1] + Array(repeating: 0, count: hypothesis.count)
            for (column, candidate) in hypothesis.enumerated() {
                current[column + 1] = min(previous[column + 1] + 1, current[column] + 1, previous[column] + (word == candidate ? 0 : 1))
            }
            previous = current
        }
        return Double(previous[hypothesis.count]) / Double(reference.count)
    }
}

@Suite(
    "Apple Intelligence (real model)",
    .enabled(if: NeuralFixtures.directory != nil && LanguageModelAvailability.current(for: .german) == .available)
)
struct LanguageModelIntegrationTests {
    @Test("The template's headings come back as one list each, in their order")
    func templateSections() async throws {
        let headings = ["Budget", "Termine", "Wetter"]
        let sections = try await SystemLanguageModelResponder().respondSections(
            headings: headings,
            instructions: "Fill each list with what the text says about its heading. Leave a list empty when the text says nothing about it. Write in German.",
            prompt: "Text:\n\nDas Budget für den Relaunch liegt bei 18.000 Euro. Der Start ist am 3. November geplant, die Abnahme eine Woche später."
        )
        #expect(sections.count == headings.count)
        #expect(sections[0].contains { $0.contains("18.000") || $0.contains("18000") })
        #expect(!sections[1].isEmpty)
    }
}
