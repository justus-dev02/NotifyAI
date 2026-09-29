//
//  KnowledgeIndexService.swift
//  NotifyAI
//

import Foundation
import Observation
import OSLog

/// Keeps the search index in sync with the notes.
///
/// Only finished notes are indexed. A cheap fingerprint decides whether a note has to be
/// indexed again, so a refresh costs almost nothing when nothing changed. Changed notes are
/// indexed in the background one at a time, and only their files are written
/// (`KnowledgeIndexStore`). Views observe `revision`, which changes once per pass, not once
/// per note, so related notes are not recomputed dozens of times while indexing.
@MainActor
@Observable
final class KnowledgeIndexService {
    private(set) var index = KnowledgeIndex()
    private(set) var isIndexing = false
    /// Changes once per refresh pass that changed something; views use it to recompute related notes.
    private(set) var revision = 0

    @ObservationIgnored let embedder: SentenceEmbedder
    @ObservationIgnored private let store: NoteStore
    /// `nil` keeps the index in memory only (tests).
    @ObservationIgnored private let persistence: KnowledgeIndexStore?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherPass = false
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private let logger = Logger.processing

    init(store: NoteStore, embedder: SentenceEmbedder, persistence: KnowledgeIndexStore?) {
        self.store = store
        self.embedder = embedder
        self.persistence = persistence
    }

    /// Indexes new and changed notes. Calls during a running pass trigger one more pass.
    func scheduleRefresh() {
        guard refreshTask == nil else {
            needsAnotherPass = true
            return
        }
        isIndexing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                needsAnotherPass = false
                await refreshPass()
            } while needsAnotherPass && !Task.isCancelled
            refreshTask = nil
            isIndexing = false
        }
    }

    /// Refreshes and waits until the index reflects all finished notes.
    func refreshAndWait() async {
        scheduleRefresh()
        while let task = refreshTask {
            await task.value
        }
    }

    /// Removes deleted notes immediately, so they never show up as sources.
    func remove(_ noteIDs: [UUID]) {
        let removed = noteIDs.filter { index.notes.removeValue(forKey: $0) != nil }
        guard !removed.isEmpty else { return }
        revision += 1
        if let persistence {
            Task { await persistence.remove(removed) }
        }
    }

    /// Discards the index and builds it again from all notes.
    func rebuild() {
        refreshTask?.cancel()
        refreshTask = nil
        needsAnotherPass = false
        index = KnowledgeIndex()
        hasLoaded = true
        revision += 1
        let persistence = persistence
        Task { [weak self] in
            await persistence?.removeAll()
            self?.scheduleRefresh()
        }
    }

    func related(to noteID: UUID, limit: Int = 5) async -> [RelatedNote] {
        let snapshot = index
        return await Task.detached(priority: .userInitiated) {
            RelatedNotesFinder(index: snapshot).related(to: noteID, limit: limit)
        }.value
    }

    // MARK: - Refresh

    private func refreshPass() async {
        if !hasLoaded {
            hasLoaded = true
            if let persistence {
                index = await persistence.load()
            }
        }
        let notes = store.notes(withStatus: [.ready])
        let liveIDs = Set(notes.map(\.id))
        let stale = index.notes.keys.filter { !liveIDs.contains($0) }
        for id in stale {
            index.notes[id] = nil
        }
        if !stale.isEmpty {
            await persistence?.remove(Array(stale))
        }

        // Everything is read from the models before the first `await`: a note may be
        // deleted while another one is indexed.
        let pending = notes.compactMap { note -> IndexableNote? in
            index.notes[note.id]?.contentHash == IndexableNote.fingerprint(of: note) ? nil : IndexableNote(note: note)
        }
        let builder = KnowledgeIndexBuilder(embedder: embedder)
        for input in pending {
            guard !Task.isCancelled else { break }
            let entry = await Task.detached(priority: .utility) { builder.entry(for: input) }.value
            guard !Task.isCancelled, store.note(id: input.id) != nil else { continue }
            index.notes[input.id] = entry
            await persistence?.save(entry)
        }

        if !stale.isEmpty || !pending.isEmpty {
            revision += 1
            logger.info("Search index updated: \(pending.count, privacy: .public) indexed, \(stale.count, privacy: .public) removed, \(self.index.notes.count, privacy: .public) notes in total")
        }
    }
}
