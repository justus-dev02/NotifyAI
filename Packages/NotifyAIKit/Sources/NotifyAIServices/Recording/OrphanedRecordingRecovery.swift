//
//  OrphanedRecordingRecovery.swift
//  NotifyAIServices
//

import AVFoundation
import Foundation
import NotifyAICore
import NotifyAIPersistence
import OSLog
import SwiftData

/// Turns audio files without a note back into notes, e.g. after the database had to be
/// reset. Recordings live outside the database, so nothing recorded is ever lost.
@MainActor
public struct OrphanedRecordingRecovery {
    /// Audio files in the recordings folder that could belong to a note.
    static let recoverableAudioExtensions: Set<String> = ["caf", "m4a", "mp3", "wav", "aif", "aiff", "aac", "mp4"]

    let store: NoteStore

    public init(store: NoteStore) {
        self.store = store
    }

    /// Creates notes for audio files in the recordings folder that no note refers to. They
    /// are queued, so processing transcribes and summarizes them again. Recordings (CAF) are
    /// readable even if the app was killed while recording them.
    /// - Returns: The identifiers of the recovered notes.
    @discardableResult
    public func recover() async throws -> [UUID] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .creationDateKey]
        let files = try FileManager.default.contentsOfDirectory(at: store.locations.recordingsDirectory, includingPropertiesForKeys: Array(keys))
        // A failed fetch must throw: treating it as "no notes" would duplicate every recording.
        let referenced = Set(try store.context.fetch(FetchDescriptor<Note>()).compactMap(\.audioFileName))
        var recovered: [UUID] = []

        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let fileExtension = file.pathExtension.lowercased()
            guard !referenced.contains(file.lastPathComponent),
                  Self.recoverableAudioExtensions.contains(fileExtension),
                  let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true
            else { continue }

            let duration = (try? await AVURLAsset(url: file).load(.duration).seconds) ?? 0
            let createdAt = values.creationDate ?? .now
            let isRecording = fileExtension == AudioFormat.recordingFileExtension
            let kind: NoteKind = isRecording ? .recording : .audioImport
            let note = Note(
                id: UUID(uuidString: file.deletingPathExtension().lastPathComponent) ?? UUID(),
                title: AutomaticTitle.make(for: kind, date: createdAt),
                isTitleUserDefined: false,
                createdAt: createdAt,
                kind: kind,
                status: .queued,
                audioFileName: file.lastPathComponent
            )
            note.duration = duration.isFinite ? duration : 0
            store.context.insert(note)
            recovered.append(note.id)
        }
        try store.save()
        if !recovered.isEmpty {
            Logger.persistence.info("Recovered \(recovered.count, privacy: .public) recordings without a note")
        }
        return recovered
    }
}
