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

    init() {
        Task { await load() }
    }

    func load() async {
        self.notes = await storage.loadAll()
        self.results = notes
        search.buildIndex(notes: notes)
    }

    func createNew() {
        var n = Note(title: "Neue Notiz")
        notes.insert(n, at: 0)
        search.buildIndex(notes: notes)
    }

    func performSearch() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = notes; return
        }
        let ids = search.search(query)
        let map = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        results = ids.compactMap { map[$0] }
    }
}
