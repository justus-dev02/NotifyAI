//
//  NotesViewModel.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import Foundation

@MainActor
final class NotesViewModel: ObservableObject {
    @Published var notes: [Note] = []
    @Published var query: String = ""
    @Published var results: [Note] = []

    private let search = SemanticSearchService.shared
    private let storage = ServiceLocator.shared.storage
    private var notesObserver: NSObjectProtocol?

    init() {
        Task { await load() }
        notesObserver = NotificationCenter.default.addObserver(forName: .notesChanged, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.load() }
        }
    }

    deinit {
        if let notesObserver {
            NotificationCenter.default.removeObserver(notesObserver)
        }
    }

    func load() async {
        self.notes = await storage.loadAll()
        self.results = notes
        search.buildIndex(notes: notes)
    }

    @discardableResult
    func createNew(title: String = "Neue Notiz") -> Note {
        let note = Note(title: title)
        notes.insert(note, at: 0)
        results = notes
        search.buildIndex(notes: notes)
        Task { await storage.save(note) }
        return note
    }

    func performSearch() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = notes
            return
        }
        let ids = search.search(query)
        let map = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        results = ids.compactMap { map[$0] }
    }

    func delete(note: Note) {
        Task {
            await storage.delete(noteId: note.id)
            if let index = notes.firstIndex(where: { $0.id == note.id }) {
                notes.remove(at: index)
                performSearch()
            }
        }
    }

    func update(note: Note) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = note
            performSearch()
        }
        Task { await storage.save(note) }
    }
}
