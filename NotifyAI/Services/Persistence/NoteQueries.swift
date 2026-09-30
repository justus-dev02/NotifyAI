//
//  NoteQueries.swift
//  NotifyAI
//

import Foundation
import NotifyAICore
import SwiftData

/// Predicates shared by views and tests.
enum NoteQueries {
    /// The notes of a library filter, optionally matching a search text in the title, the
    /// summary overview or the full text.
    ///
    /// The full text lives in `NoteContent`; the predicate follows the relationship inside
    /// the database, so searching does not load any text into memory.
    static func library(filter: LibraryFilter, searchText: String) -> Predicate<Note> {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let recording = NoteKind.recording.rawValue
        let favoritesOnly = filter == .favorites
        let recordingsOnly = filter == .recordings
        let importsOnly = filter == .imports

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
}
