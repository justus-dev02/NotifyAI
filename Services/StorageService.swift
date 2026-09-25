//
//  StorageService.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//  Updated for High-Performance Manifest Caching & Async Disk I/O.
//

import Foundation

actor StorageService {
    private nonisolated let fm = FileManager.default
    private var notes: [UUID: Note] = [:]
    private var hasLoadedFromDisk = false

    func loadAll() async -> [Note] {
        if !hasLoadedFromDisk {
            loadFromDisk()
            hasLoadedFromDisk = true
        }
        return Array(notes.values).sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ note: Note) async {
        notes[note.id] = note
        persist(note)
        saveManifest()
        broadcastChange()
    }

    func updateSegments(noteId: UUID, segments: [TranscriptSegment]) async {
        guard var n = notes[noteId] else { return }
        n.segments = segments
        notes[noteId] = n
        persist(n)
        saveManifest()
        broadcastChange()
    }

    func updateSummaries(noteId: UUID, summary: Summary, roleSummaries: [String: Summary], mindmap: Mindmap) async {
        guard var n = notes[noteId] else { return }
        n.summary = summary
        n.roleSummaries = roleSummaries
        n.mindmap = mindmap

        notes[noteId] = n
        persist(n)
        saveManifest()
        broadcastChange()
    }

    func updatePipeline(noteId: UUID, _ block: (inout PipelineState) -> Void) async {
        guard var n = notes[noteId] else { return }
        block(&n.pipeline)
        notes[noteId] = n
        persist(n)
        saveManifest()
        broadcastChange()
    }

    func delete(noteId: UUID) async {
        notes.removeValue(forKey: noteId)
        let dir = documentsURL().appendingPathComponent(noteId.uuidString, isDirectory: true)
        try? fm.removeItem(at: dir)
        saveManifest()
        broadcastChange()
    }

    func pendingNotes() async -> [Note] {
        if !hasLoadedFromDisk {
            loadFromDisk()
            hasLoadedFromDisk = true
        }
        return notes.values.filter { $0.pipeline.stage != .done && $0.audioURL != nil }
    }

    nonisolated func temporaryAudioURL(for id: UUID) -> URL {
        fm.temporaryDirectory.appendingPathComponent("rec_\(id).caf")
    }

    private func loadFromDisk() {
        let manifestFile = documentsURL().appendingPathComponent("manifest.json")
        if fm.fileExists(atPath: manifestFile.path),
           let data = try? Data(contentsOf: manifestFile),
           let manifestNotes = try? JSONDecoder().decode([Note].self, from: data) {
            for note in manifestNotes {
                notes[note.id] = note
            }
            if !notes.isEmpty {
                return
            }
        }

        // Fallback: Scan subdirectories
        let docURL = documentsURL()
        guard let subdirs = try? fm.contentsOfDirectory(at: docURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return
        }

        for folderURL in subdirs {
            let metaFile = folderURL.appendingPathComponent("note.json")
            if fm.fileExists(atPath: metaFile.path) {
                if let data = try? Data(contentsOf: metaFile),
                   let note = try? JSONDecoder().decode(Note.self, from: data) {
                    notes[note.id] = note
                }
            }
        }
        saveManifest()
    }

    private func persist(_ note: Note) {
        let dir = documentsURL().appendingPathComponent(note.id.uuidString, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta = dir.appendingPathComponent("note.json")
        do {
            let data = try JSONEncoder().encode(note)
            try data.write(to: meta, options: .atomic)
        } catch {
            print("StorageService persist error: \(error)")
        }
    }

    private func saveManifest() {
        let manifestFile = documentsURL().appendingPathComponent("manifest.json")
        let allNotes = Array(notes.values)
        if let data = try? JSONEncoder().encode(allNotes) {
            try? data.write(to: manifestFile, options: .atomic)
        }
    }

    private func broadcastChange() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .notesChanged, object: nil)
        }
    }

    private func documentsURL() -> URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
