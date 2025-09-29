//
//  DashboardViewModel.swift
//  NotifyAI
//
//  Created by Justus on 29.09.25.
//

import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var notes: [Note] = []
    @Published var query: String = ""

    private let storage = ServiceLocator.shared.storage
    private let search = SemanticSearchService.shared
    private var pipelineObserver: NSObjectProtocol?
    private var notesObserver: NSObjectProtocol?
    private var allNotes: [Note] = []

    init() {
        Task { await refresh() }
        pipelineObserver = NotificationCenter.default.addObserver(forName: .pipelineUpdated, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.refresh() }
        }
        notesObserver = NotificationCenter.default.addObserver(forName: .notesChanged, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    deinit {
        if let pipelineObserver {
            NotificationCenter.default.removeObserver(pipelineObserver)
        }
        if let notesObserver {
            NotificationCenter.default.removeObserver(notesObserver)
        }
    }

    func refresh() async {
        allNotes = await storage.loadAll()
        search.buildIndex(notes: allNotes)
        applyQuery()
    }

    func performSearch() {
        applyQuery()
    }

    func newNote() {
        let note = Note(title: "Neue Notiz")
        allNotes.insert(note, at: 0)
        search.buildIndex(notes: allNotes)
        Task { await storage.save(note) }
        applyQuery()
    }

    private func applyQuery() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            notes = allNotes
        } else {
            let ids = search.search(trimmed)
            let map = Dictionary(uniqueKeysWithValues: allNotes.map { ($0.id, $0) })
            notes = ids.compactMap { map[$0] }
        }
    }
}

