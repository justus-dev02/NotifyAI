//
//  NotifyAISchemaV4.swift
//  NotifyAIPersistence
//

import Foundation
import NotifyAICore
import SwiftData

/// Tasks become their own entity.
///
/// Until V3, the tasks of a summary were part of the summary's JSON. Listing the open tasks of
/// all notes meant decoding every summary, ticking one off meant re-encoding its whole
/// summary, and a task could not be part of a query. Now every task is a `NoteTask` row with
/// its resolved due date; the summary's JSON holds everything else. `Note.summary` joins both,
/// so readers of the summary see no difference.
public enum NotifyAISchemaV4: VersionedSchema {
    public static let versionIdentifier = Schema.Version(4, 0, 0)
    public static var models: [any PersistentModel.Type] { [Note.self, NoteContent.self, NoteTask.self] }

    /// A recording, imported audio file or imported document.
    ///
    /// Enum-typed values are stored as raw strings so they can be used in `#Predicate`.
    /// Large or structured values (text, transcript, markers, summary) are stored outside
    /// the row or as encoded JSON and decoded on demand: the library list never loads them.
    @Model
    public final class Note {
        #Index<Note>([\.createdAt])

        @Attribute(.unique) public package(set) var id: UUID
        public package(set) var title: String
        /// `false` while the title is generated automatically, so the summary may replace it.
        public package(set) var isTitleUserDefined: Bool
        public package(set) var createdAt: Date
        public package(set) var kindRawValue: String
        public package(set) var statusRawValue: String
        /// Human-readable reason when `status == .failed`.
        public package(set) var statusMessage: String?
        public package(set) var duration: TimeInterval
        public package(set) var isFavorite: Bool
        public package(set) var focusRawValue: String
        public package(set) var languageID: String
        /// Which engine produced the transcript.
        public package(set) var transcriptionEngineRawValue: String?
        public package(set) var participants: [String]
        /// When the user confirmed that everybody present agreed to being recorded.
        public package(set) var consentConfirmedAt: Date?
        /// File name inside the recordings directory. Stored relative on purpose: absolute
        /// container paths change between app installs and updates.
        public package(set) var audioFileName: String?
        /// The text of V2 notes. The migration to V3 moves it into `content` and leaves it
        /// empty; nothing reads it afterwards.
        @Attribute(originalName: "bodyText") public package(set) var legacyBodyText: String = ""
        @Attribute(.externalStorage) public package(set) var transcriptData: Data?
        public package(set) var markersData: Data?
        public package(set) var summaryData: Data?
        /// Copy of the summary overview so that search can match it.
        public package(set) var summaryOverview: String
        /// `RecordingAudioSource` raw value. `nil` for notes created before system audio
        /// recording existed, which were all recorded with the microphone.
        public package(set) var audioSourceRawValue: String?
        /// Name of the app whose audio was recorded, `nil` for all apps or microphone only.
        public package(set) var sourceAppName: String?
        /// Encoded `SourceActivity` of a microphone + system audio recording.
        @Attribute(.externalStorage) public package(set) var sourceActivityData: Data?
        /// Transcript text or extracted document text, loaded only on access.
        @Relationship(deleteRule: .cascade, inverse: \NoteContent.note) public package(set) var content: NoteContent?
        /// Number of characters of `content.text`.
        public package(set) var textLength: Int = 0
        /// Increases whenever the text, transcript or summary changes (not when a task is
        /// ticked off). The search index re-indexes a note only when it changed.
        public package(set) var contentRevision: Int = 0
        /// The tasks of the summary, in the summary's order (`NoteTask.position`).
        @Relationship(deleteRule: .cascade, inverse: \NoteTask.note) public package(set) var tasks: [NoteTask] = []

        /// Decoded summary and markers, reused while their data is unchanged. Not stored. A
        /// reference that is never replaced: filling it does not count as a change of the note.
        @Transient let decodingCache = DecodingCache()

        public init(
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
            self.tasks = []
        }
    }

    /// The full text of a note, in its own table so it is only loaded when needed.
    @Model
    public final class NoteContent {
        public package(set) var text: String
        public package(set) var note: Note?

        public init(text: String) {
            self.text = text
        }
    }

    /// One task of a note's summary.
    ///
    /// The due date is resolved once, when the summary is saved, relative to the day the note
    /// was recorded ("bis Freitag" means the Friday after the meeting, not after today).
    @Model
    public final class NoteTask {
        #Index<NoteTask>([\.isDone], [\.dueDate])

        @Attribute(.unique) public package(set) var id: UUID
        public package(set) var task: String
        /// Who takes care of it, as mentioned.
        public package(set) var owner: String?
        /// The deadline as it was mentioned ("bis Freitag").
        public package(set) var due: String?
        /// The day `due` refers to, if it could be resolved.
        public package(set) var dueDate: Date?
        public package(set) var isDone: Bool
        /// Position within the summary's tasks.
        public package(set) var position: Int
        /// Where the task was mentioned in the recording, in seconds.
        public package(set) var sourceTime: TimeInterval?
        public package(set) var note: Note?

        public init(
            id: UUID,
            task: String,
            owner: String?,
            due: String?,
            dueDate: Date?,
            isDone: Bool,
            position: Int,
            sourceTime: TimeInterval?
        ) {
            self.id = id
            self.task = task
            self.owner = owner
            self.due = due
            self.dueDate = dueDate
            self.isDone = isDone
            self.position = position
            self.sourceTime = sourceTime
        }
    }
}
