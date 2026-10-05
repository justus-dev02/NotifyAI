//
//  KnowledgeIndexService.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore
import NotifyAIPersistence
import Observation
import OSLog

/// Keeps the search index in sync with the notes.
///
/// It follows the store on its own: every save schedules a refresh and deleted notes leave
/// the index at once. Only finished notes are indexed. A cheap fingerprint decides whether a
/// note has to be indexed again, so a refresh costs almost nothing when nothing changed.
/// Changed notes are indexed in the background one at a time, and only their files are written
/// (`KnowledgeIndexStore`). Views observe `revision`, which changes once per pass, not once
/// per note, so related notes are not recomputed dozens of times while indexing.
@MainActor
@Observable
public final class KnowledgeIndexService {
    public private(set) var index = KnowledgeIndex()
    public private(set) var isIndexing = false
    /// Changes once per refresh pass that changed something; views use it to recompute related notes.
    public private(set) var revision = 0

    @ObservationIgnored let embedder: any SentenceEmbedding
    @ObservationIgnored private let store: NoteStore
    /// `nil` keeps the index in memory only (tests).
    @ObservationIgnored private let persistence: (any KnowledgeIndexPersisting)?
    /// The last queued write. Writes run one after another in the order they were queued,
    /// so removing a note's file can never overtake the save of the same note.
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherPass = false
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var subscriptions: [EventSubscription] = []
    @ObservationIgnored private let logger = Logger.processing

    init(store: NoteStore, embedder: any SentenceEmbedding, persistence: (any KnowledgeIndexPersisting)?) {
        self.store = store
        self.embedder = embedder
        self.persistence = persistence
        store.events.subscribe { [weak self] event in
            switch event {
            case .saved:
                // Cheap when nothing indexed changed: the pass compares fingerprints.
                self?.scheduleRefresh()
            case .deleted(let ids):
                self?.remove(ids)
            case .saveFailed, .deleteFailed:
                break
            }
        }.store(in: &subscriptions)
    }

    /// Indexes new and changed notes. Calls during a running pass trigger one more pass.
    public func scheduleRefresh() {
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

    /// Refreshes and waits until the index reflects all finished notes and its files are written.
    func refreshAndWait() async {
        scheduleRefresh()
        while let task = refreshTask {
            await task.value
        }
        await waitForPendingWrites()
    }

    /// Waits until every queued write of the index files is done.
    func waitForPendingWrites() async {
        while let write = pendingWrite {
            await write.value
            // Writes queued while waiting are awaited too.
            if pendingWrite == write {
                pendingWrite = nil
            }
        }
    }

    /// Removes deleted notes immediately, so they never show up as sources.
    func remove(_ noteIDs: [UUID]) {
        let removed = noteIDs.filter { index.notes.removeValue(forKey: $0) != nil }
        guard !removed.isEmpty else { return }
        revision += 1
        enqueueWrite { await $0.remove(removed) }
    }

    /// Discards the index and builds it again from all notes.
    public func rebuild() {
        refreshTask?.cancel()
        refreshTask = nil
        needsAnotherPass = false
        index = KnowledgeIndex()
        hasLoaded = true
        revision += 1
        // The pass's saves are queued after the removal, so they survive it.
        enqueueWrite { await $0.removeAll() }
        scheduleRefresh()
    }

    public func related(to noteID: UUID, limit: Int = 5) async -> [RelatedNote] {
        await Self.related(to: noteID, in: index, limit: limit)
    }

    @concurrent
    private static func related(to noteID: UUID, in index: KnowledgeIndex, limit: Int) async -> [RelatedNote] {
        RelatedNotesFinder(index: index).related(to: noteID, limit: limit)
    }

    // MARK: - Refresh

    private func refreshPass() async {
        let interval = Signposts.knowledge.beginInterval("Refresh index")
        defer { Signposts.knowledge.endInterval("Refresh index", interval) }
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
            enqueueWrite { await $0.remove(stale) }
        }

        // Everything is read from the models before the first `await`: a note may be
        // deleted while another one is indexed.
        let pending = notes.compactMap { note -> IndexableNote? in
            index.notes[note.id]?.contentHash == IndexableNote.fingerprint(of: note) ? nil : IndexableNote(note: note)
        }
        let builder = KnowledgeIndexBuilder(embedder: embedder)
        for input in pending {
            guard !Task.isCancelled else { break }
            let entry = await BackgroundWork.run(priority: .utility) { builder.entry(for: input) }
            guard !Task.isCancelled, store.note(id: input.id) != nil else { continue }
            index.notes[input.id] = entry
            enqueueWrite { await $0.save(entry) }
        }

        if !stale.isEmpty || !pending.isEmpty {
            revision += 1
            logger.info("Search index updated: \(pending.count, privacy: .public) indexed, \(stale.count, privacy: .public) removed, \(self.index.notes.count, privacy: .public) notes in total")
        }
    }

    // MARK: - Writing

    /// Queues a write after all earlier ones; without persistence (tests) nothing happens.
    private func enqueueWrite(_ write: @escaping @Sendable (any KnowledgeIndexPersisting) async -> Void) {
        guard let persistence else { return }
        let previous = pendingWrite
        pendingWrite = Task {
            await previous?.value
            await write(persistence)
        }
    }
}
