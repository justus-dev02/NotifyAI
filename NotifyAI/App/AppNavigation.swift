//
//  AppNavigation.swift
//  NotifyAI
//

import Foundation
import Observation

/// Filters of the note library.
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all
    case favorites
    case recordings
    case imports

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Alle Notizen"
        case .favorites: "Favoriten"
        case .recordings: "Aufnahmen"
        case .imports: "Importe"
        }
    }

    var symbolName: String {
        switch self {
        case .all: "tray.full"
        case .favorites: "star"
        case .recordings: "waveform"
        case .imports: "square.and.arrow.down"
        }
    }
}

/// Shared navigation state, so that e.g. the menu bar can open a note in the main window.
@MainActor
@Observable
final class AppNavigation {
    var selectedNoteID: UUID?
    var filter: LibraryFilter = .all
    var searchText = ""
    var isRecorderPresented = false
    var isSettingsPresented = false
    var isChatPresented = false
    /// A transcript position to show, e.g. after tapping a source in the chat.
    var transcriptFocus: TranscriptFocus?

    /// Opens a note, optionally at a position in its transcript.
    func open(noteID: UUID, at time: TimeInterval? = nil) {
        selectedNoteID = noteID
        transcriptFocus = time.map { TranscriptFocus(noteID: noteID, time: $0) }
    }
}

struct TranscriptFocus: Equatable {
    let noteID: UUID
    let time: TimeInterval
}
