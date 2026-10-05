//
//  NotifyAISchemaV2.swift
//  NotifyAIPersistence
//

import Foundation
import NotifyAICore
import SwiftData

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
    public final class Note {
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
