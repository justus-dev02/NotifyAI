//
//  NotifyAISchemaV6.swift
//  NotifyAIPersistence
//

import Foundation
import NotifyAICore
import SwiftData

/// Recordings without their audio, and tasks of the user's own.
///
/// - `Note.audioRemovedAt`: when the user deleted the recording to save space. Transcript,
///   summary, tasks and speakers stay; playing and transcribing again are no longer possible.
/// - `NoteTask.isUserEdited`: the user added or changed the task. Summarizing again keeps it
///   instead of replacing it with what the model finds.
///
/// One optional attribute and one with a default value: SwiftData migrates V5 without code.
public enum NotifyAISchemaV6: VersionedSchema {
    public static let versionIdentifier = Schema.Version(6, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [Note.self, NoteContent.self, NoteTask.self, VoiceProfile.self, SummaryTemplate.self]
    }

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
        /// Encoded `[NoteSpeaker]`: the speakers of the transcript with their voice prints.
        @Attribute(.externalStorage) public package(set) var speakersData: Data?
        /// The user's own template for the summary; `nil` uses the built-in one of `focus`.
        public package(set) var summaryTemplateID: UUID?
        /// When the user last corrected the transcript; `nil` if it is as recognized.
        public package(set) var transcriptEditedAt: Date?
        /// When the user deleted the recording's audio file; `audioFileName` is `nil` since.
        public package(set) var audioRemovedAt: Date?

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
            self.speakersData = nil
            self.summaryTemplateID = nil
            self.transcriptEditedAt = nil
            self.audioRemovedAt = nil
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
        /// The user added or changed the task; summarizing again keeps it as it is.
        public package(set) var isUserEdited: Bool = false
        public package(set) var note: Note?

        public init(
            id: UUID,
            task: String,
            owner: String?,
            due: String?,
            dueDate: Date?,
            isDone: Bool,
            position: Int,
            sourceTime: TimeInterval?,
            isUserEdited: Bool = false
        ) {
            self.id = id
            self.task = task
            self.owner = owner
            self.due = due
            self.dueDate = dueDate
            self.isDone = isDone
            self.position = position
            self.sourceTime = sourceTime
            self.isUserEdited = isUserEdited
        }
    }

    /// A voice the user named, recognized again in later recordings.
    ///
    /// The voice print is the mean of the voice prints of every recording in which the user
    /// confirmed the name (L2-normalized), so it becomes more reliable with each one.
    @Model
    public final class VoiceProfile {
        @Attribute(.unique) public package(set) var id: UUID
        public package(set) var name: String
        /// The user's own voice ("Ich").
        public package(set) var isUser: Bool
        /// Encoded `[Float]`.
        public package(set) var voicePrintData: Data
        /// Recordings (or enrollments) the voice print was learned from.
        public package(set) var sampleCount: Int
        /// Seconds of speech the voice print was learned from.
        public package(set) var speechDuration: TimeInterval
        public package(set) var createdAt: Date
        public package(set) var updatedAt: Date

        public init(
            id: UUID = UUID(),
            name: String,
            isUser: Bool = false,
            voicePrintData: Data,
            sampleCount: Int = 1,
            speechDuration: TimeInterval = 0,
            createdAt: Date = .now
        ) {
            self.id = id
            self.name = name
            self.isUser = isUser
            self.voicePrintData = voicePrintData
            self.sampleCount = sampleCount
            self.speechDuration = speechDuration
            self.createdAt = createdAt
            self.updatedAt = createdAt
        }
    }

    /// A template of the user's own for summaries: what the summary should focus on, which
    /// sections it has and which headings of its own it adds.
    @Model
    public final class SummaryTemplate {
        @Attribute(.unique) public package(set) var id: UUID
        public package(set) var name: String
        /// SF Symbol shown next to the name.
        public package(set) var symbolName: String
        /// What the summary should pay attention to, in the user's words.
        public package(set) var instructions: String
        /// Encoded `Set<SummarySection>`: which of the standard sections are generated.
        public package(set) var sectionsData: Data
        /// Headings of the user's own ("Kundenwünsche", "Risiken"), each filled with points.
        public package(set) var customHeadings: [String]
        public package(set) var createdAt: Date
        public package(set) var updatedAt: Date

        public init(
            id: UUID = UUID(),
            name: String,
            symbolName: String,
            instructions: String,
            sectionsData: Data,
            customHeadings: [String],
            createdAt: Date = .now
        ) {
            self.id = id
            self.name = name
            self.symbolName = symbolName
            self.instructions = instructions
            self.sectionsData = sectionsData
            self.customHeadings = customHeadings
            self.createdAt = createdAt
            self.updatedAt = createdAt
        }
    }
}
