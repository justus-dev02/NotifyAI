//
//  RecordingNoteWriter.swift
//  NotifyAIServices
//

import AudioCapture
import Foundation
import NotifyAICore
import NotifyAIPersistence

/// Creates the note of a new recording and completes it when the recording stops.
@MainActor
struct RecordingNoteWriter {
    let store: NoteStore

    /// The note as it is stored while recording: title, context and consent.
    func makeNote(draft: RecordingController.Draft, configuration: CaptureConfiguration, language: TranscriptionLanguage) -> Note {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let participants = draft.participants
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let id = UUID()
        let note = Note(
            id: id,
            title: title.isEmpty ? AutomaticTitle.make(for: .recording) : title,
            isTitleUserDefined: !title.isEmpty,
            kind: .recording,
            status: .recording,
            focus: draft.focus,
            language: language,
            participants: participants,
            consentConfirmedAt: .now,
            audioFileName: NoteStore.recordingFileName(for: id)
        )
        note.audioSource = configuration.source
        if configuration.source.usesSystemAudio, case .app(_, let name) = configuration.systemAudioTarget {
            note.sourceAppName = name
        }
        return note
    }

    /// Stores duration, markers, source levels and the live transcript, and gives a recording
    /// without a user title a title from its keywords right away (the summary refines it).
    func complete(
        noteID: UUID,
        result: RecordingResult,
        markers: [Marker],
        transcript: [TranscriptSegment],
        engine: TranscriptionEngineKind
    ) async {
        guard let note = store.note(id: noteID) else { return }
        let needsTitle = !note.isTitleUserDefined && !transcript.isEmpty
        let languageCode = note.language.languageCode
        let createdAt = note.createdAt
        let text = transcript.map(\.text).joined(separator: " ")
        let (encoded, plainText, keywords) = await Self.prepare(
            transcript,
            titleKeywordsFrom: needsTitle ? text : nil,
            languageCode: languageCode
        )

        // The note may have been deleted while the keywords were computed.
        guard let note = store.note(id: noteID) else { return }
        note.duration = result.duration
        note.markers = markers
        note.sourceActivity = result.sourceActivity
        note.status = .queued
        if !transcript.isEmpty, let encoded {
            note.setTranscript(encoded: encoded, plainText: plainText, engine: engine)
        }
        if !keywords.isEmpty {
            note.title = AutomaticTitle.make(keywords: keywords, date: createdAt)
        }
        store.saveReportingErrors()
    }

    /// Encodes the transcript and finds title keywords, off the main actor.
    @concurrent
    private static func prepare(
        _ transcript: [TranscriptSegment],
        titleKeywordsFrom text: String?,
        languageCode: String
    ) async -> (encoded: Data?, plainText: String, keywords: [String]) {
        (
            try? Transcript.encode(transcript),
            Transcript.plainText(of: transcript),
            text.map { TextAnalysis.keywords(in: $0, languageCode: languageCode, limit: 2) } ?? []
        )
    }
}
