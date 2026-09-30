//
//  NoteKind.swift
//  NotifyAICore
//

import Foundation

/// Where a note's content came from.
public enum NoteKind: String, Codable, CaseIterable, Sendable {
    case recording
    case audioImport
    case document
    case image

    public var symbolName: String {
        switch self {
        case .recording: "waveform"
        case .audioImport: "music.note"
        case .document: "doc.text"
        case .image: "text.viewfinder"
        }
    }

    /// Whether the note has an audio file that needs transcription.
    public var hasAudio: Bool { self == .recording || self == .audioImport }
}

/// Lifecycle of a note. Persisted so interrupted work can resume after a relaunch.
public enum NoteStatus: String, Codable, Sendable {
    case recording
    case queued
    case transcribing
    case identifyingSpeakers
    case summarizing
    case ready
    case failed

    public var isProcessing: Bool {
        switch self {
        case .queued, .transcribing, .identifyingSpeakers, .summarizing: true
        case .recording, .ready, .failed: false
        }
    }

}
