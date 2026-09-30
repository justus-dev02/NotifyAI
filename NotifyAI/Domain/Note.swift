//
//  Note.swift
//  NotifyAI
//

import Foundation
import NotifyAICore
import SwiftData

typealias Note = NotifyAISchemaV3.Note
typealias NoteContent = NotifyAISchemaV3.NoteContent

/// Moves the full text out of the note's row and tracks content changes.
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

/// Adds the audio source of a recording (microphone and/or system audio on the Mac).
/// Frozen: never change it, add a new version instead.
enum NotifyAISchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [Note.self] }

    /// A recording, imported audio file or imported document.
    ///
    /// Enum-typed values are stored as raw strings so they can be used in `#Predicate`.
    /// Large or structured values (transcript, markers, summary) are stored as encoded
    /// JSON and decoded on demand: the library list never has to load them.
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
        /// Transcript text or extracted document text. Used for search and summarization.
        var bodyText: String
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
            self.bodyText = bodyText
            self.transcriptData = nil
            self.markersData = nil
            self.summaryData = nil
            self.summaryOverview = ""
            self.audioSourceRawValue = nil
            self.sourceAppName = nil
            self.sourceActivityData = nil
        }
    }
}

/// The first released schema. Frozen: never change it, add a new version instead.
enum NotifyAISchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [Note.self] }

    /// A recording, imported audio file or imported document.
    ///
    /// Enum-typed values are stored as raw strings so they can be used in `#Predicate`.
    /// Large or structured values (transcript, markers, summary) are stored as encoded
    /// JSON and decoded on demand: the library list never has to load them.
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
        /// Transcript text or extracted document text. Used for search and summarization.
        var bodyText: String
        @Attribute(.externalStorage) var transcriptData: Data?
        var markersData: Data?
        var summaryData: Data?
        /// Copy of the summary overview so that search can match it.
        var summaryOverview: String

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
            self.bodyText = bodyText
            self.transcriptData = nil
            self.markersData = nil
            self.summaryData = nil
            self.summaryOverview = ""
        }
    }
}

enum NotifyAIMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [NotifyAISchemaV1.self, NotifyAISchemaV2.self, NotifyAISchemaV3.self] }
    static var stages: [MigrationStage] { [v1ToV2, v2ToV3] }

    /// V2 only adds optional attributes, which SwiftData migrates without custom code.
    static var v1ToV2: MigrationStage {
        .lightweight(fromVersion: NotifyAISchemaV1.self, toVersion: NotifyAISchemaV2.self)
    }

    /// The schema change (new entity, renamed and new attributes) is inferred; afterwards
    /// every note's text moves from its row into its own `NoteContent`.
    static var v2ToV3: MigrationStage {
        .custom(fromVersion: NotifyAISchemaV2.self, toVersion: NotifyAISchemaV3.self, willMigrate: nil) { context in
            try moveTextIntoContent(in: context)
        }
    }

    /// Moves `legacyBodyText` into `content`, in batches so a large library never has all
    /// texts in memory at once.
    static func moveTextIntoContent(in context: ModelContext, batchSize: Int = 50) throws {
        var descriptor = FetchDescriptor<NotifyAISchemaV3.Note>(
            predicate: #Predicate { !$0.legacyBodyText.isEmpty },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = batchSize
        while true {
            let batch = try context.fetch(descriptor)
            guard !batch.isEmpty else { break }
            for note in batch {
                let text = note.legacyBodyText
                let content = NotifyAISchemaV3.NoteContent(text: text)
                context.insert(content)
                note.content = content
                note.textLength = text.count
                note.contentRevision = 1
                note.legacyBodyText = ""
            }
            try context.save()
        }
    }
}

// MARK: - Typed accessors

extension Note {
    var kind: NoteKind {
        get { NoteKind(rawValue: kindRawValue) ?? .recording }
        set { kindRawValue = newValue.rawValue }
    }

    var status: NoteStatus {
        get { NoteStatus(rawValue: statusRawValue) ?? .failed }
        set { statusRawValue = newValue.rawValue }
    }

    var focus: RecordingFocus {
        get { RecordingFocus(rawValue: focusRawValue) ?? .general }
        set { focusRawValue = newValue.rawValue }
    }

    var language: TranscriptionLanguage {
        get { TranscriptionLanguage(id: languageID) }
        set { languageID = newValue.id }
    }

    var transcriptionEngine: TranscriptionEngineKind? {
        get { transcriptionEngineRawValue.flatMap(TranscriptionEngineKind.init(rawValue:)) }
        set { transcriptionEngineRawValue = newValue?.rawValue }
    }

    var hasTranscript: Bool { transcriptData != nil }

    /// Transcript text or extracted document text. Reading loads `content`; call it only
    /// where the text is needed (detail, export, indexing, summarizing), never in lists.
    var bodyText: String {
        get { content?.text ?? "" }
        set {
            if let content {
                content.text = newValue
            } else if !newValue.isEmpty {
                let content = NoteContent(text: newValue)
                modelContext?.insert(content)
                self.content = content
            }
            textLength = newValue.count
            contentRevision += 1
        }
    }

    /// Whether the note has text, without loading it.
    var hasText: Bool { textLength > 0 }

    var audioSource: RecordingAudioSource {
        get { audioSourceRawValue.flatMap(RecordingAudioSource.init(rawValue:)) ?? .microphone }
        set { audioSourceRawValue = newValue.rawValue }
    }

    var sourceActivity: SourceActivity? {
        get {
            guard let sourceActivityData else { return nil }
            return try? JSONDecoder().decode(SourceActivity.self, from: sourceActivityData)
        }
        set {
            sourceActivityData = newValue.flatMap { try? JSONEncoder().encode($0) }
        }
    }

    /// "Mikrofon + Zoom", "Systemton · Alle Apps" …; `nil` for microphone recordings.
    var audioSourceDescription: String? {
        let app = sourceAppName ?? SystemAudioTarget.allApps.displayName
        return switch audioSource {
        case .microphone: nil
        case .microphoneAndSystemAudio: sourceAppName.map { String(localized: "Mikrofon + \($0)") } ?? RecordingAudioSource.microphoneAndSystemAudio.title
        case .systemAudio: String(localized: "Systemton · \(app)")
        }
    }

    var markers: [Marker] {
        get {
            guard let markersData else { return [] }
            return (try? JSONDecoder().decode([Marker].self, from: markersData)) ?? []
        }
        set {
            markersData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue.sorted { $0.time < $1.time })
        }
    }

    /// Setting a summary counts as a content change (the search index re-indexes the note).
    /// Ticking off a task uses `setActionItem(_:isDone:)`, which does not.
    var summary: NoteSummary? {
        get {
            guard let summaryData else { return nil }
            return try? JSONDecoder().decode(NoteSummary.self, from: summaryData)
        }
        set {
            summaryData = newValue.flatMap { try? JSONEncoder().encode($0) }
            summaryOverview = newValue?.overview ?? ""
            contentRevision += 1
        }
    }

    /// Marks a task of the summary as done or open.
    /// - Returns: `false` if the note has no such task.
    @discardableResult
    func setActionItem(_ id: ActionItem.ID, isDone: Bool) -> Bool {
        guard var summary, let index = summary.actionItems.firstIndex(where: { $0.id == id }) else { return false }
        summary.actionItems[index].isDone = isDone
        summaryData = try? JSONEncoder().encode(summary)
        return true
    }

    /// Decodes the transcript. Callers should cache the result; decoding a long
    /// transcript is not free.
    func decodedTranscript() -> [TranscriptSegment] {
        guard let transcriptData else { return [] }
        return (try? Transcript.decode(transcriptData)) ?? []
    }

    /// Stores an already encoded transcript together with its plain text.
    func setTranscript(encoded data: Data, plainText: String, engine: TranscriptionEngineKind?) {
        transcriptData = data
        bodyText = plainText
        transcriptionEngine = engine
    }

    /// Removes the transcript, e.g. before transcribing again.
    func clearTranscript() {
        transcriptData = nil
        transcriptionEngine = nil
        bodyText = ""
    }

    func markFailed(_ message: String) {
        status = .failed
        statusMessage = message
    }

    static func automaticTitle(for kind: NoteKind, date: Date = .now) -> String {
        "\(kind.displayName) \(date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))"
    }
}
