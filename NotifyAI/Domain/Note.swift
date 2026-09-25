//
//  Note.swift
//  NotifyAI
//

import Foundation
import SwiftData

/// Where a note's content came from.
enum NoteKind: String, Codable, CaseIterable, Sendable {
    case recording
    case audioImport
    case document
    case image

    var displayName: String {
        switch self {
        case .recording: "Aufnahme"
        case .audioImport: "Audiodatei"
        case .document: "PDF"
        case .image: "Bild"
        }
    }

    var symbolName: String {
        switch self {
        case .recording: "waveform"
        case .audioImport: "music.note"
        case .document: "doc.text"
        case .image: "text.viewfinder"
        }
    }

    /// Whether the note has an audio file that needs transcription.
    var hasAudio: Bool { self == .recording || self == .audioImport }
}

/// Lifecycle of a note. Persisted so interrupted work can resume after a relaunch.
enum NoteStatus: String, Codable, Sendable {
    case recording
    case queued
    case transcribing
    case identifyingSpeakers
    case summarizing
    case ready
    case failed

    var isProcessing: Bool {
        switch self {
        case .queued, .transcribing, .identifyingSpeakers, .summarizing: true
        case .recording, .ready, .failed: false
        }
    }

    var displayName: String {
        switch self {
        case .recording: "Aufnahme läuft"
        case .queued: "In Warteschlange"
        case .transcribing: "Wird transkribiert"
        case .identifyingSpeakers: "Sprecher werden erkannt"
        case .summarizing: "Wird zusammengefasst"
        case .ready: "Fertig"
        case .failed: "Fehlgeschlagen"
        }
    }
}

typealias Note = NotifyAISchemaV1.Note

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
    static var schemas: [any VersionedSchema.Type] { [NotifyAISchemaV1.self] }
    static var stages: [MigrationStage] { [] }
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

    var markers: [Marker] {
        get {
            guard let markersData else { return [] }
            return (try? JSONDecoder().decode([Marker].self, from: markersData)) ?? []
        }
        set {
            markersData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue.sorted { $0.time < $1.time })
        }
    }

    var summary: NoteSummary? {
        get {
            guard let summaryData else { return nil }
            return try? JSONDecoder().decode(NoteSummary.self, from: summaryData)
        }
        set {
            summaryData = newValue.flatMap { try? JSONEncoder().encode($0) }
            summaryOverview = newValue?.overview ?? ""
        }
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

    func markFailed(_ message: String) {
        status = .failed
        statusMessage = message
    }

    static func automaticTitle(for kind: NoteKind, date: Date = .now) -> String {
        "\(kind.displayName) \(date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))"
    }
}
