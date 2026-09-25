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
}
