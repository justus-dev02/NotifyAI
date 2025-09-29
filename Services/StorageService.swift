//
//  StorageService.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import Foundation

actor StorageService {
    private nonisolated let fm = FileManager.default
    private var notes: [UUID: Note] = [:]

    func loadAll() async -> [Note] { Array(notes.values).sorted{ $0.createdAt > $1.createdAt } }
    func save(_ note: Note) async {
        notes[note.id] = note
        persist(note)
        broadcastChange()
    }
    func updateSegments(noteId: UUID, segments: [TranscriptSegment]) async {
        guard var n = notes[noteId] else { return }
        n.segments = segments
        notes[noteId] = n
        persist(n)
        broadcastChange()
    }
    func updateSummaries(noteId: UUID, summary: Summary, roleSummaries: [String: Summary], mindmap: Mindmap) async {
        guard var n = notes[noteId] else { return }
        n.summary = summary; n.roleSummaries = roleSummaries
        n.mindmap = mindmap

        notes[noteId] = n
        persist(n)
        broadcastChange()
    }
    func updatePipeline(noteId: UUID, _ block: (inout PipelineState)->Void) async {
        guard var n = notes[noteId] else { return }
        block(&n.pipeline)
        notes[noteId] = n
        persist(n)
        broadcastChange()
    }
    func pendingNotes() async -> [Note] { notes.values.filter{ $0.pipeline.stage != .done && $0.audioURL != nil } }

    nonisolated func temporaryAudioURL(for id: UUID) -> URL {
        fm.temporaryDirectory.appendingPathComponent("rec_\(id).caf")
    }

    private func persist(_ note: Note) {
        let dir = documentsURL().appendingPathComponent(note.id.uuidString, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta = dir.appendingPathComponent("note.json")
        do { let data = try JSONEncoder().encode(note); try data.write(to: meta) } catch { print(error) }

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
