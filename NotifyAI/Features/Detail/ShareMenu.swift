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

/// Shares, copies or saves a note as Markdown. Sharing is always an explicit user action;
/// nothing leaves the app automatically.
///
/// Sharing hands over the text itself (Mail, Messages, Notes); saving writes a `.md` file
/// to a place the user chooses.
struct ShareMenu: View {
    let note: Note
    let segments: [TranscriptSegment]
    /// Asks the detail screen to save the document as a file.
    let onSave: (MarkdownDocument) -> Void

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
            Section {
                Button("Als Markdown kopieren", systemImage: "doc.on.doc") {
                    Clipboard.copy(document(redacted: false).text)
                }
                Button("Als Datei sichern …", systemImage: "square.and.arrow.down") {
                    onSave(document(redacted: false))
                }
            }
        }
        .disabled(note.status == .recording)
    }

    private func document(redacted: Bool, includesTranscript: Bool = true) -> MarkdownDocument {
        let snapshot = MarkdownExporter.NoteSnapshot(note: note, segments: segments)
        let options = MarkdownExporter.Options(includesTranscript: includesTranscript, redactsPersonalData: redacted)
        return MarkdownDocument(snapshot: snapshot, options: options)
    }
}

/// A note's Markdown as a file for `fileExporter`.
struct MarkdownFile: FileDocument {
    static let readableContentTypes: [UTType] = [.markdownText, .plainText]

    let text: String
    let fileName: String

    init(document: MarkdownDocument) {
        text = document.text
        fileName = document.fileName
    }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
        fileName = configuration.file.filename ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
