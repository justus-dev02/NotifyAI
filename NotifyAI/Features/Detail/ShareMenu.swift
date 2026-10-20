//
//  ShareMenu.swift
//  NotifyAI
//

import DesignSystem
import NotifyAICore
import NotifyAIPersistence
import NotifyAIServices
import SwiftUI
import UniformTypeIdentifiers

/// Shares, copies, saves or sends a note. Sharing is always an explicit user action; only the
/// integrations the user set to automatic send without asking.
///
/// Sharing as Markdown hands over the text itself (Mail, Messages, Notes); the other formats
/// are files. Saving writes a file to a place the user chooses.
struct ShareMenu: View {
    let note: Note
    let segments: [TranscriptSegment]
    /// Asks the detail screen to save the note as a file.
    let onSave: (ExportedFile) -> Void
    @Environment(IntegrationService.self) private var integrations
    @Environment(UserNotices.self) private var notices

    var body: some View {
        Menu("Teilen", systemImage: "square.and.arrow.up") {
            Section {
                ShareLink(item: document(redacted: false), preview: SharePreview(note.title)) {
                    Label("Als Markdown teilen", systemImage: "doc.text")
                }
                ShareLink(item: document(redacted: true), preview: SharePreview(note.title)) {
                    Label("Anonymisiert teilen", systemImage: "eye.slash")
                }
                ShareLink(item: document(redacted: false, includesTranscript: false), preview: SharePreview(note.title)) {
                    Label("Nur Zusammenfassung teilen", systemImage: "sparkles")
                }
            }
            Section("Als Datei") {
                ForEach(fileFormats) { format in
                    let file = file(format)
                    ShareLink(item: file, preview: SharePreview(file.fileName)) {
                        Label(String(localized: "\(format.title) teilen"), systemImage: format.symbolName)
                    }
                }
                Menu("Sichern als …", systemImage: "square.and.arrow.down") {
                    ForEach(availableFormats) { format in
                        Button(format.title, systemImage: format.symbolName) { onSave(file(format)) }
                    }
                }
                Button("Als Markdown kopieren", systemImage: "doc.on.doc") {
                    Clipboard.copy(document(redacted: false).text)
                }
            }
            let targets = IntegrationTarget.allCases.filter(integrations.isConfigured)
            if !targets.isEmpty {
                Section("Senden an") {
                    ForEach(targets) { target in
                        Button(target.name, systemImage: target.symbolName) { send(to: target) }
                            .disabled(integrations.sending[note.id]?.contains(target) == true || note.status != .ready)
                    }
                }
            }
        }
        .disabled(note.status == .recording)
    }

    /// Subtitles need a transcript with times.
    private var availableFormats: [ExportFormat] {
        ExportFormat.allCases.filter { !$0.needsTranscript || !segments.isEmpty }
    }

    /// The formats offered as files; Markdown is shared as text above.
    private var fileFormats: [ExportFormat] {
        availableFormats.filter { $0 != .markdown }
    }

    private var snapshot: MarkdownExporter.NoteSnapshot {
        MarkdownExporter.NoteSnapshot(note: note, segments: segments)
    }

    private func document(redacted: Bool, includesTranscript: Bool = true) -> MarkdownDocument {
        MarkdownDocument(snapshot: snapshot, options: MarkdownExporter.Options(includesTranscript: includesTranscript, redactsPersonalData: redacted))
    }

    private func file(_ format: ExportFormat) -> ExportedFile {
        ExportedFile(snapshot: snapshot, options: MarkdownExporter.Options(), format: format)
    }

    private func send(to target: IntegrationTarget) {
        Task {
            do {
                let location = try await integrations.send(note, to: target)
                notices.post(UserNotice(title: String(localized: "An \(target.name) gesendet"), message: confirmation(for: target, location: location)))
            } catch {
                notices.post(UserNotice(title: String(localized: "Nicht an \(target.name) gesendet"), message: error.localizedDescription, noteID: note.id))
            }
        }
    }

    private func confirmation(for target: IntegrationTarget, location: URL?) -> String {
        switch target {
        case .obsidian: String(localized: "Die Notiz liegt als „\(location?.lastPathComponent ?? note.title)“ im Obsidian-Ordner.")
        case .notion: String(localized: "Die Notiz wurde als Seite in Notion angelegt.")
        case .webhook: String(localized: "Die Notiz wurde an den Webhook übertragen.")
        }
    }
}

/// An exported note as a file for `fileExporter`.
struct ExportFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = []
    static var writableContentTypes: [UTType] { ExportFormat.allCases.map(\.contentType) }

    let data: Data
    let fileName: String
    let contentType: UTType

    init(file: ExportedFile) {
        data = file.data
        fileName = file.fileName
        contentType = file.format.contentType
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
