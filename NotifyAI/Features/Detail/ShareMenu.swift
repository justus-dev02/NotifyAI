//
//  ShareMenu.swift
//  NotifyAI
//

import NotifyAICore
import SwiftUI

/// Exports a note as Markdown. Sharing is always an explicit user action; nothing leaves
/// the app automatically.
struct ShareMenu: View {
    let note: Note
    let segments: [TranscriptSegment]

    var body: some View {
        Menu("Teilen", systemImage: "square.and.arrow.up") {
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
        .disabled(note.status == .recording)
    }

    private func document(redacted: Bool, includesTranscript: Bool = true) -> MarkdownDocument {
        let snapshot = MarkdownExporter.NoteSnapshot(
            title: note.title,
            createdAt: note.createdAt,
            duration: note.duration,
            participants: note.participants,
            summary: note.summary,
            markers: note.markers,
            segments: segments,
            bodyText: note.bodyText,
            audioSource: note.audioSourceDescription
        )
        let options = MarkdownExporter.Options(includesTranscript: includesTranscript, redactsPersonalData: redacted)
        return MarkdownDocument(snapshot: snapshot, options: options)
    }
}
