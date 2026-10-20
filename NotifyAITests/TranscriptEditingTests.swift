//
//  TranscriptEditingTests.swift
//  NotifyAITests
//
//  Corrections of the transcript: changed text keeps its timing, fillers disappear without
//  touching real words, the vocabulary corrects near-misses only.
//

import Foundation
@testable import NotifyAI
import NotifyAICore
@testable import NotifyAIPersistence
@testable import NotifyAIServices
import Testing

@Suite("Filler words")
struct FillerWordTests {
    let german = FillerWords(languageCode: "de")

    @Test("Fillers disappear with their commas; real words that contain them stay")
    func removesFillers() throws {
        let segment = segment("Äh, wir treffen uns, ähm, um zehn Uhr in der Hummelstraße.", at: 0)
        let cleaned = try #require(german.remove(from: segment))
        #expect(cleaned.text == "Wir treffen uns um zehn Uhr in der Hummelstraße.")
        // Concatenated words still reproduce the text.
        #expect(cleaned.words.map(\.text).joined() == cleaned.text)
        // The first remaining word starts the segment.
        #expect(cleaned.start == 1)
    }

    @Test("A filler at the end of a sentence hands over its full stop")
    func sentenceEnd() throws {
        let cleaned = try #require(german.remove(from: segment("Das war es, äh.", at: 0)))
        #expect(cleaned.text == "Das war es.")
    }

    @Test("Segments of only fillers are dropped; segments without timings are cleaned too")
    func onlyFillersAndPlainText() {
        #expect(german.remove(from: segment("Ähm.", at: 0)) == nil)
        let plain = TranscriptSegment(start: 0, end: 3, text: "Hm, also gut.")
        #expect(german.remove(from: plain)?.text == "Also gut.")
    }

    @Test("Fillers are per language: “um” stays in German, goes in English")
    func perLanguage() {
        let english = FillerWords(languageCode: "en")
        #expect(english.remove(from: segment("We meet um at ten.", at: 0))?.text == "We meet at ten.")
        #expect(german.remove(from: segment("Wir treffen uns um zehn.", at: 0))?.text == "Wir treffen uns um zehn.")
        #expect(german.remove(from: segment("Er kommt eh später.", at: 0))?.text == "Er kommt eh später.")
    }
}

@Suite("Custom vocabulary")
struct CustomVocabularyTests {
    let vocabulary = CustomVocabulary(["Schmiernow", "NotifyAI", "Kubernetes", "Q3-Budget", "Anna Weber"])

    @Test("Near-misses of a term are corrected, with their punctuation")
    func correctsNearMisses() {
        let segments = [segment("Frag Herrn Schmirnow, ob Kubernetis läuft.", at: 0)]
        let corrected = vocabulary.corrected(segments)
        #expect(corrected[0].text == "Frag Herrn Schmiernow, ob Kubernetes läuft.")
        #expect(corrected[0].words.map(\.text).joined() == corrected[0].text)
    }

    @Test("Real words are left alone: other first letter, too different, too short")
    func leavesWordsAlone() {
        let segments = [segment("Wir schmieren Brote und kochen Nudeln.", at: 0)]
        #expect(vocabulary.corrected(segments) == segments)
    }

    @Test("The prompt lists the terms; duplicates and blanks are dropped")
    func prompt() {
        let vocabulary = CustomVocabulary(["NotifyAI", " notifyai ", "", "Anna Weber"])
        #expect(vocabulary.terms == ["NotifyAI", "Anna Weber"])
        #expect(vocabulary.prompt == " NotifyAI, Anna Weber.")
        #expect(CustomVocabulary([]).prompt == nil)
    }
}

@Suite("Word timing after corrections")
struct WordRetimingTests {
    let words = segment("wir treffen uns am Freitag", at: 10).words

    @Test("Unchanged words keep their timing, also with new case and punctuation")
    func keepsTiming() {
        let retimed = WordRetiming.retime(words, to: "Wir treffen uns am Freitag.", from: 10, to: 15)
        #expect(retimed.map(\.start) == words.map(\.start))
        #expect(retimed.map(\.text).joined() == "Wir treffen uns am Freitag.")
    }

    @Test("A replaced word takes the time of the word it replaces")
    func replacement() {
        let retimed = WordRetiming.retime(words, to: "wir sehen uns am Freitag", from: 10, to: 15)
        #expect(retimed[1].text == " sehen")
        #expect(abs(retimed[1].start - words[1].start) < 1e-9)
        #expect(abs(retimed[1].end - words[1].end) < 1e-9)
    }

    @Test("Inserted words share the gap; removed words leave no trace")
    func insertionAndDeletion() {
        let inserted = WordRetiming.retime(words, to: "wir treffen uns wieder am Freitag", from: 10, to: 15)
        #expect(inserted.count == 6)
        #expect(inserted[3].text == " wieder")
        #expect(inserted[3].start >= words[2].end && inserted[3].end <= words[3].start + 1e-9)
        let removed = WordRetiming.retime(words, to: "wir treffen uns Freitag", from: 10, to: 15)
        #expect(removed.map(\.start) == [words[0].start, words[1].start, words[2].start, words[4].start])
    }
}

@Suite("Correcting a transcript")
@MainActor
struct TranscriptEditorTests {
    let store: NoteStore
    let editor: TranscriptEditor

    init() throws {
        store = try NoteStore(locations: try StorageLocations.temporary(), inMemory: true)
        editor = TranscriptEditor(store: store)
    }

    private func makeNote() throws -> Note {
        let note = Note(title: "Meeting", isTitleUserDefined: true, kind: .recording, status: .ready)
        let segments = [segment("Hallo, äh, zusammen.", at: 0), segment("Das Budget sind zwölf tausend Euro.", at: 4)]
        note.setTranscript(encoded: try Transcript.encode(segments), plainText: Transcript.plainText(of: segments), engine: .whisper)
        try store.insert(note)
        return note
    }

    @Test("Corrected text is saved with its timing and marks the transcript as edited")
    func applyCorrections() async throws {
        let note = try makeNote()
        let revision = note.contentRevision
        let segment = note.decodedTranscript()[1]
        let changed = try await editor.apply([segment.id: "Das Budget sind 12.000 Euro."], to: note)

        #expect(changed)
        let corrected = note.decodedTranscript()[1]
        #expect(corrected.id == segment.id)
        #expect(corrected.text == "Das Budget sind 12.000 Euro.")
        #expect(corrected.words.first?.start == segment.words.first?.start)
        #expect(note.bodyText.contains("12.000 Euro"))
        #expect(note.transcriptEditedAt != nil)
        #expect(note.contentRevision > revision)
    }

    @Test("Unchanged text changes nothing; an empty text removes the passage")
    func noChangeAndRemoval() async throws {
        let note = try makeNote()
        let segments = note.decodedTranscript()
        #expect(try await !editor.apply([segments[0].id: segments[0].text], to: note))
        #expect(note.transcriptEditedAt == nil)

        try await editor.apply([segments[0].id: "  "], to: note)
        #expect(note.decodedTranscript().map(\.id) == [segments[1].id])
    }

    @Test("Removing fillers from a note")
    func removeFillers() async throws {
        let note = try makeNote()
        #expect(try await editor.removeFillerWords(in: note))
        #expect(note.decodedTranscript()[0].text == "Hallo zusammen.")
        #expect(try await !editor.removeFillerWords(in: note))
    }

    @Test("The cleanup step removes fillers from new transcripts only when enabled and not edited")
    func cleanupStep() async throws {
        let settings = makeIsolatedSettings()
        let step = CleanupStep(settings: settings.transcription)
        let note = try makeNote()
        #expect(!step.needsToRun(for: note))

        settings.transcription.removesFillerWords = true
        #expect(step.needsToRun(for: note))
        let context = ProcessingContext(store: store, noteID: note.id, setStage: { _, _ in }, progress: { _ in })
        try await step.run(note, context: context)
        #expect(note.decodedTranscript()[0].text == "Hallo zusammen.")
        // Not an edit by the user.
        #expect(note.transcriptEditedAt == nil)

        try await editor.apply([note.decodedTranscript()[0].id: "Hallo, ähm, ihr."], to: note)
        #expect(!step.needsToRun(for: note))
    }
}
