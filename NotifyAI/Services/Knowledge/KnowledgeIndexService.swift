//
//  KnowledgeIndexService.swift
//  NotifyAI
//

import Foundation
import Observation
import OSLog

/// Keeps the search index in sync with the notes and stores it on disk.
///
/// Only finished notes are indexed. A content fingerprint decides whether a note has to be
/// indexed again, so a refresh is cheap when nothing changed. Indexing runs in the
/// background, one note at a time; the index is written once per pass.
@MainActor
@Observable
final class KnowledgeIndexService {
    private(set) var index = KnowledgeIndex()
    private(set) var isIndexing = false
    /// Increases with every change; views use it to recompute related notes.
    private(set) var revision = 0

    @ObservationIgnored let embedder: SentenceEmbedder
    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherPass = false
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger.processing

    /// - Parameter fileURL: Where the index is stored; `nil` keeps it in memory (tests).
    init(store: NoteStore, embedder: SentenceEmbedder, fileURL: URL?) {
        self.store = store
        self.embedder = embedder
        self.fileURL = fileURL
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
        var changed = false
        for id in noteIDs where index.notes.removeValue(forKey: id) != nil {
            changed = true
        }
        if changed {
            revision += 1
            save()
        }
    }

    /// Discards the index and builds it again from all notes.
    func rebuild() {
        refreshTask?.cancel()
        refreshTask = nil
        index = KnowledgeIndex()
        revision += 1
        scheduleRefresh()
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
            await load()
        }
        let notes = store.notes(withStatus: [.ready])
        let liveIDs = Set(notes.map(\.id))
        var changed = false
        for id in index.notes.keys where !liveIDs.contains(id) {
            index.notes[id] = nil
            changed = true
        }

        // Everything is read from the models before the first `await`: a note may be
        // deleted while another one is indexed.
        let pending = notes.compactMap { note -> IndexableNote? in
            index.notes[note.id]?.contentHash == IndexableNote.contentHash(of: note) ? nil : IndexableNote(note: note)
        }
        let builder = KnowledgeIndexBuilder(embedder: embedder)
        for input in pending {
            guard !Task.isCancelled else { return }
            let entry = await Task.detached(priority: .utility) { builder.entry(for: input) }.value
            guard !Task.isCancelled, store.note(id: input.id) != nil else { continue }
            index.notes[input.id] = entry
            revision += 1
            changed = true
        }
        if changed {
            revision += 1
            save()
            logger.info("Search index updated: \(self.index.notes.count, privacy: .public) notes, \(self.index.passageCount, privacy: .public) passages")
        }
    }

    // MARK: - Persistence

    private func load() async {
        hasLoaded = true
        guard let fileURL else { return }
        let loaded = await Task.detached(priority: .utility) { () -> KnowledgeIndex? in
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return try? PropertyListDecoder().decode(KnowledgeIndex.self, from: data)
        }.value
        // An index from an older format is rebuilt instead of migrated.
        if let loaded, loaded.formatVersion == KnowledgeIndex.formatVersion, index.notes.isEmpty {
            index = loaded
            revision += 1
        }
    }

    private func save() {
        guard let fileURL else { return }
        let snapshot = index
        let logger = logger
        let previous = saveTask
        // Writes run one after another, so an older snapshot never overwrites a newer one.
        saveTask = Task.detached(priority: .utility) {
            await previous?.value
            do {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let data = try encoder.encode(snapshot)
                #if os(iOS)
                // Contains transcript text: protected like the recordings.
                try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                #else
                try data.write(to: fileURL, options: .atomic)
                #endif
            } catch {
                logger.error("Saving the search index failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
