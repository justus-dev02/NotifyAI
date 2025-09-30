//
//  DashboardViewModel.swift
//  NotifyAI
//
//  Created by Justus on 29.09.25.
//

import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var notes: [Note] = []
    @Published var query: String = ""
    @Published var activeFilter: Filter = .all {
        didSet { applyQuery() }
    }

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
        let base: [Note]
        if trimmed.isEmpty {
            base = allNotes
        } else {
            let ids = search.search(trimmed)
            let map = Dictionary(uniqueKeysWithValues: allNotes.map { ($0.id, $0) })
            base = ids.compactMap { map[$0] }
        }
        notes = base.filter { activeFilter.matches($0) }
    }

    func toggle(filter: Filter) {
        activeFilter = activeFilter == filter ? .all : filter
    }

    func startRecording() {
        NotificationCenter.default.post(name: .dashboardStartRecording, object: nil)
    }

    func showImportHub() {
        NotificationCenter.default.post(name: .dashboardOpenImport, object: nil)
    }

    func showScanner() {
        NotificationCenter.default.post(name: .dashboardOpenScanner, object: nil)
    }
}

extension DashboardViewModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all
        case meetings
        case pdf
        case web
        case audio
        case favorites

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "Alle"
            case .meetings: return "Meetings"
            case .pdf: return "PDFs"
            case .web: return "Web"
            case .audio: return "Audio"
            case .favorites: return "Favoriten"
            }
        }

        func matches(_ note: Note) -> Bool {
            switch self {
            case .all:
                return true
            case .meetings:
                return note.sourceType == .meeting
            case .pdf:
                return note.sourceType == .pdf
            case .web:
                return note.sourceType == .web
            case .audio:
                return note.sourceType == .audio
            case .favorites:
                return note.isFavorite
            }
        }
    }
}

