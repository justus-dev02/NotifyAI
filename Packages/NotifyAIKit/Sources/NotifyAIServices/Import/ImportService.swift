//
//  ImportService.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore
import NotifyAIPersistence
import Observation
import OSLog

/// Turns imported files into notes and queues them for processing.
@MainActor
@Observable
public final class ImportService {
    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let processing: ProcessingCoordinator

    init(store: NoteStore, settings: AppSettings, processing: ProcessingCoordinator) {
        self.store = store
        self.settings = settings
        self.processing = processing
    }

    /// Imports a file picked by the user.
    /// - Returns: The identifier of the new note.
    @discardableResult
    public func importFile(at url: URL) async throws -> UUID {
        let title = url.deletingPathExtension().lastPathComponent
        let content = try await DocumentImporter.content(of: url, languages: [settings.transcription.language])

        let note: Note
        switch content {
        case .audio(let duration):
            note = Note(title: title, isTitleUserDefined: false, kind: .audioImport, status: .queued, language: settings.transcription.language)
            note.duration = duration
            // Copy while the security-scoped resource is accessible.
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
            }
            note.audioFileName = try store.importAudioFile(from: url, noteID: note.id)
        case .text(let text, let kind):
            note = Note(title: title, isTitleUserDefined: false, kind: kind, status: .queued, language: settings.transcription.language, bodyText: text)
        }

        try store.insert(note)
        processing.enqueue(.process(note.id))
        Logger.importing.info("Imported a \(note.kind.rawValue, privacy: .public) file")
        return note.id
    }

    /// Imports an image picked from the photo library.
    @discardableResult
    public func importImage(data: Data) async throws -> UUID {
        let text = try await DocumentImporter.recognizedText(inImageData: data, languages: [settings.transcription.language])
        let note = Note(
            title: AutomaticTitle.make(for: .image),
            isTitleUserDefined: false,
            kind: .image,
            status: .queued,
            language: settings.transcription.language,
            bodyText: text
        )
        try store.insert(note)
        processing.enqueue(.process(note.id))
        return note.id
    }
}
