//
//  NoteLabels.swift
//  NotifyAILibrary
//

import Foundation
import NotifyAICore
import NotifyAIPersistence
import NotifyAISupport
import Observation
import SwiftData

/// A label and how many notes carry it.
public struct LabelUsage: Identifiable, Hashable, Sendable {
    public let name: String
    public let noteCount: Int
    public var id: String { NoteLabel.key(name) }
}

/// The labels of all notes: giving, renaming and removing them.
///
/// A label is written the same way everywhere: a label given to a note takes the spelling it
/// already has on other notes ("samsung" becomes "Samsung"). Every change reaches the search
/// index through the store's events; the summary uses labels the next time it is made.
@MainActor
@Observable
public final class NoteLabels {
    @ObservationIgnored private let store: NoteStore

    package init(store: NoteStore) {
        self.store = store
    }

    /// All labels in use, most used first, then alphabetically.
    public func all() -> [LabelUsage] {
        var names: [String: String] = [:]
        var counts: [String: Int] = [:]
        for note in labeledNotes() {
            for label in note.labels {
                let key = NoteLabel.key(label)
                names[key] = names[key] ?? label
                counts[key, default: 0] += 1
            }
        }
        return names.map { LabelUsage(name: $0.value, noteCount: counts[$0.key] ?? 0) }
            .sorted { $0.noteCount != $1.noteCount ? $0.noteCount > $1.noteCount : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Gives a note its labels, in the spelling the labels already have elsewhere.
    /// - Returns: Whether the change was saved.
    @discardableResult
    public func setLabels(_ labels: [String], for note: Note) -> Bool {
        let known = Dictionary(all().map { (NoteLabel.key($0.name), $0.name) }, uniquingKeysWith: { first, _ in first })
        let spelled = NoteLabel.unique(labels).map { known[NoteLabel.key($0)] ?? $0 }
        note.setLabels(spelled)
        return store.saveReportingErrors()
    }

    /// Adds one label to a note.
    @discardableResult
    public func add(_ label: String, to note: Note) -> Bool {
        guard NoteLabel.normalized(label) != nil else { return false }
        return setLabels(note.labels + [label], for: note)
    }

    /// Removes one label from a note.
    @discardableResult
    public func remove(_ label: String, from note: Note) -> Bool {
        let key = NoteLabel.key(label)
        return setLabels(note.labels.filter { NoteLabel.key($0) != key }, for: note)
    }

    /// Renames a label on every note. Renaming to an existing label merges both.
    /// - Returns: How many notes changed; `nil` if the new name is empty or saving failed.
    @discardableResult
    public func rename(_ label: String, to newName: String) -> Int? {
        guard let name = NoteLabel.normalized(newName) else { return nil }
        let key = NoteLabel.key(label)
        let notes = labeledNotes().filter { $0.labels.contains { NoteLabel.key($0) == key } }
        for note in notes {
            note.setLabels(note.labels.map { NoteLabel.key($0) == key ? name : $0 })
        }
        return store.saveReportingErrors() ? notes.count : nil
    }

    /// Removes a label from every note. The notes stay.
    /// - Returns: How many notes changed; `nil` if saving failed.
    @discardableResult
    public func delete(_ label: String) -> Int? {
        let key = NoteLabel.key(label)
        let notes = labeledNotes().filter { $0.labels.contains { NoteLabel.key($0) == key } }
        for note in notes {
            note.setLabels(note.labels.filter { NoteLabel.key($0) != key })
        }
        return store.saveReportingErrors() ? notes.count : nil
    }

    private func labeledNotes() -> [Note] {
        store.fetch(FetchDescriptor<Note>(predicate: #Predicate { !$0.labelKeys.isEmpty }))
    }
}
