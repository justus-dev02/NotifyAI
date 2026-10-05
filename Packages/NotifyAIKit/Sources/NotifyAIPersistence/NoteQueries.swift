//
//  NoteQueries.swift
//  NotifyAIPersistence
//

import Foundation
import NotifyAICore
import SwiftData

/// Which notes a list shows. The app maps its filters (`LibraryFilter`) onto this, so the
/// persistence layer knows nothing about the screens that use it.
public struct NoteListFilter: Equatable, Sendable {
    public enum Origin: Sendable {
        case any
        case recordings
        case imports
    }

    public var favoritesOnly: Bool
    public var origin: Origin

    public init(favoritesOnly: Bool = false, origin: Origin = .any) {
        self.favoritesOnly = favoritesOnly
        self.origin = origin
    }
}

/// Predicates shared by views, services and tests.
public enum NoteQueries {
    /// The notes of a list filter, optionally matching a search text in the title, the
    /// summary overview or the full text.
    ///
    /// The full text lives in `NoteContent`; the predicate follows the relationship inside
    /// the database, so searching does not load any text into memory.
    public static func library(filter: NoteListFilter, searchText: String) -> Predicate<Note> {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let recording = NoteKind.recording.rawValue
        let favoritesOnly = filter.favoritesOnly
        let recordingsOnly = filter.origin == .recordings
        let importsOnly = filter.origin == .imports

        return #Predicate<Note> { note in
            (!favoritesOnly || note.isFavorite)
                && (!recordingsOnly || note.kindRawValue == recording)
                && (!importsOnly || note.kindRawValue != recording)
                && (query.isEmpty
                    || note.title.localizedStandardContains(query)
                    || note.summaryOverview.localizedStandardContains(query)
                    || note.content.flatMap { $0.text.localizedStandardContains(query) } == true)
        }
    }

    /// One note by identifier, for views that follow a single note with `@Query`.
    public static func note(id: UUID) -> Predicate<Note> {
        #Predicate<Note> { $0.id == id }
    }
}
