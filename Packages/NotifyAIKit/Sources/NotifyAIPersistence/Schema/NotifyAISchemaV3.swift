//
//  NotifyAISchemaV3.swift
//  NotifyAIPersistence
//

import Foundation
import NotifyAICore
import SwiftData

/// Moves the full text out of the note's row and tracks content changes.
/// Frozen: never change it, add a new version instead.
///
/// - The transcript or document text (up to several hundred KB for a four-hour recording) now
///   lives in `NoteContent`, a separate entity. Fetching notes for the library no longer
///   loads it; it is read only when a note is opened, exported or indexed. Search still
///   matches it through the relationship in the database.
/// - `textLength` answers "is there text?" without loading the text.
/// - `contentRevision` increases whenever indexed content changes, so the search index
///   compares a number instead of hashing text.
enum NotifyAISchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] { [Note.self, NoteContent.self] }

    /// A recording, imported audio file or imported document.
    ///
    /// Enum-typed values are stored as raw strings so they can be used in `#Predicate`.
    /// Large or structured values (text, transcript, markers, summary) are stored outside
    /// the row or as encoded JSON and decoded on demand: the library list never loads them.
    @Model
    final class Note {
        #Index<Note>([\.createdAt])

        @Attribute(.unique) var id: UUID
        var title: String
        /// `false` while the title is generated automatically, so the summary may replace it.
        var isTitleUserDefined: Bool
        var createdAt: Date
        var kindRawValue: String
        var statusRawValue: String
        /// Human-readable reason when `status == .failed`.
        var statusMessage: String?
        var duration: TimeInterval
        var isFavorite: Bool
        var focusRawValue: String
        var languageID: String
        /// Which engine produced the transcript.
        var transcriptionEngineRawValue: String?
        var participants: [String]
        /// When the user confirmed that everybody present agreed to being recorded.
        var consentConfirmedAt: Date?
        /// File name inside the recordings directory. Stored relative on purpose: absolute
        /// container paths change between app installs and updates.
        var audioFileName: String?
        /// The text of V2 notes. The migration to V3 moves it into `content` and leaves it
        /// empty; nothing reads it afterwards.
        @Attribute(originalName: "bodyText") var legacyBodyText: String = ""
        @Attribute(.externalStorage) var transcriptData: Data?
        var markersData: Data?
        var summaryData: Data?
        /// Copy of the summary overview so that search can match it.
        var summaryOverview: String
        /// `RecordingAudioSource` raw value. `nil` for notes created before system audio
        /// recording existed, which were all recorded with the microphone.
        var audioSourceRawValue: String?
        /// Name of the app whose audio was recorded, `nil` for all apps or microphone only.
        var sourceAppName: String?
        /// Encoded `SourceActivity` of a microphone + system audio recording.
        @Attribute(.externalStorage) var sourceActivityData: Data?
        /// Transcript text or extracted document text, loaded only on access.
        @Relationship(deleteRule: .cascade, inverse: \NoteContent.note) var content: NoteContent?
        /// Number of characters of `content.text`.
        var textLength: Int = 0
        /// Increases whenever the text, transcript or summary changes (not when a task is
        /// ticked off). The search index re-indexes a note only when it changed.
        var contentRevision: Int = 0

        init(
            id: UUID = UUID(),
            title: String,
            isTitleUserDefined: Bool,
            createdAt: Date = .now,
            kind: NoteKind,
            status: NoteStatus,
            focus: RecordingFocus = .general,
            language: TranscriptionLanguage = .german,
            participants: [String] = [],
            consentConfirmedAt: Date? = nil,
            audioFileName: String? = nil,
            bodyText: String = ""
        ) {
            self.id = id
            self.title = title
            self.isTitleUserDefined = isTitleUserDefined
            self.createdAt = createdAt
            self.kindRawValue = kind.rawValue
            self.statusRawValue = status.rawValue
            self.statusMessage = nil
            self.duration = 0
            self.isFavorite = false
            self.focusRawValue = focus.rawValue
            self.languageID = language.id
            self.transcriptionEngineRawValue = nil
            self.participants = participants
            self.consentConfirmedAt = consentConfirmedAt
            self.audioFileName = audioFileName
            self.legacyBodyText = ""
            self.transcriptData = nil
            self.markersData = nil
            self.summaryData = nil
            self.summaryOverview = ""
            self.audioSourceRawValue = nil
            self.sourceAppName = nil
            self.sourceActivityData = nil
            self.content = bodyText.isEmpty ? nil : NoteContent(text: bodyText)
            self.textLength = bodyText.count
            self.contentRevision = 0
        }
    }

    /// The full text of a note, in its own table so it is only loaded when needed.
    @Model
    final class NoteContent {
        var text: String
        var note: Note?

        init(text: String) {
            self.text = text
        }
    }
}
