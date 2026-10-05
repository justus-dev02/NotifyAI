//
//  AppNavigation.swift
//  NotifyAI
//

import Foundation
import NotifyAIPersistence
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
        case .all: String(localized: "Alle Notizen")
        case .favorites: String(localized: "Favoriten")
        case .recordings: String(localized: "Aufnahmen")
        case .imports: String(localized: "Importe")
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

    /// The notes the filter shows, for the store's queries.
    var listFilter: NoteListFilter {
        switch self {
        case .all: NoteListFilter()
        case .favorites: NoteListFilter(favoritesOnly: true)
        case .recordings: NoteListFilter(origin: .recordings)
        case .imports: NoteListFilter(origin: .imports)
        }
    }
}

/// What the library's list shows in the detail column.
enum LibrarySelection: Hashable {
    case note(UUID)
    /// The open tasks of all notes.
    case tasks
}

/// Shared navigation state, so that e.g. the menu bar can open a note in the main window.
@MainActor
@Observable
final class AppNavigation {
    var selection: LibrarySelection?
    var filter: LibraryFilter = .all
    var searchText = ""
    var isRecorderPresented = false
    var isSettingsPresented = false
    var isChatPresented = false
    /// A transcript position to show, e.g. after tapping a source in the chat.
    var transcriptFocus: TranscriptFocus?

    /// The selected note, if a note (and not the task overview) is selected.
    var selectedNoteID: UUID? {
        get {
            if case .note(let id) = selection { id } else { nil }
        }
        set {
            selection = newValue.map(LibrarySelection.note)
        }
    }

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
