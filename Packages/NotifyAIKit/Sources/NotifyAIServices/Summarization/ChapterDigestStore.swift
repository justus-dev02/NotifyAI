//
//  ChapterDigestStore.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore
import OSLog

/// Stores chapter digests while a long summary is being made.
///
/// One small JSON file per note, keyed by `TranscriptChapter.key`. Digests are written as
/// soon as they exist: after an interruption (app terminated, background time expired,
/// device restarted) the summary continues with the first missing chapter. Digests made
/// while recording end up here too. The file is removed once the summary is finished or
/// the note is deleted.
actor ChapterDigestStore {
    /// `nil` keeps everything in memory (tests).
    private let directory: URL?
    private var cache: [UUID: [String: ChapterDigest]] = [:]
    private let logger = Logger.summarization

    init(directory: URL?) {
        self.directory = directory
    }

    func digest(noteID: UUID, key: String) -> ChapterDigest? {
        digests(for: noteID)[key]
    }

    func save(_ digest: ChapterDigest, noteID: UUID, key: String) {
        var digests = digests(for: noteID)
        digests[key] = digest
        cache[noteID] = digests
        guard let url = fileURL(for: noteID) else { return }
        do {
            let data = try JSONEncoder().encode(digests)
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
        } catch {
            logger.error("Saving a chapter digest failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func count(noteID: UUID) -> Int {
        digests(for: noteID).count
    }

    func remove(noteID: UUID) {
        cache[noteID] = nil
        guard let url = fileURL(for: noteID) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Private

    private func digests(for noteID: UUID) -> [String: ChapterDigest] {
        if let cached = cache[noteID] {
            return cached
        }
        guard let url = fileURL(for: noteID),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: ChapterDigest].self, from: data)
        else {
            return [:]
        }
        cache[noteID] = decoded
        return decoded
    }

    private func fileURL(for noteID: UUID) -> URL? {
        directory?.appending(path: "\(noteID.uuidString).json", directoryHint: .notDirectory)
    }
}

/// The stored chapter digests of one note: where a chapter-wise summary continues after an
/// interruption.
struct NoteDigests: Sendable {
    let store: ChapterDigestStore
    let noteID: UUID

    func digest(key: String) async -> ChapterDigest? {
        await store.digest(noteID: noteID, key: key)
    }

    func save(_ digest: ChapterDigest, key: String) async {
        await store.save(digest, noteID: noteID, key: key)
    }
}
