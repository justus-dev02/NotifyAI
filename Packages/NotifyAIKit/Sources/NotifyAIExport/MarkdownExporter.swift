//
//  MarkdownExporter.swift
//  NotifyAIExport
//

import CoreTransferable
import Foundation
import NotifyAICore
import NotifyAIPersistence
import NotifyAISummarization
import NotifyAISupport
import UniformTypeIdentifiers

/// Renders a note as Markdown for sharing.
public struct MarkdownExporter {
    package init() {

    }

    public struct Options: Sendable {
        package var includesTranscript = true
        /// Replaces e-mail addresses, phone numbers and IBANs.
        package var redactsPersonalData = false

        public init(includesTranscript: Bool = true, redactsPersonalData: Bool = false) {
            self.includesTranscript = includesTranscript
            self.redactsPersonalData = redactsPersonalData
        }
    }

    public struct NoteSnapshot: Sendable {
        package var id = UUID()
        package var title: String
        package var createdAt: Date
        package var duration: TimeInterval
        package var participants: [String]
        package var summary: NoteSummary?
        var markers: [Marker]
        package var segments: [TranscriptSegment]
        var bodyText: String
        /// "Mikrofon + Zoom" etc.; `nil` for microphone recordings and imports.
        var audioSource: String?
        /// Keywords of the summary, e.g. for tags in Obsidian.
        package var keywords: [String] = []
        /// The user's labels ("Samsung"): metadata and tags in Obsidian.
        package var labels: [String] = []
        /// For a summary across several notes: its notes ("Weekly · 14. Okt. 2026").
        var sources: [String] = []
    }

    package func markdown(for note: NoteSnapshot, options: Options = Options()) -> String {
        render(ExportDocument(note: note, options: options))
    }

    /// The document as Markdown: a level-1 block is a `##` heading, every content block is
    /// separated by an empty line.
    func render(_ document: ExportDocument) -> String {
        var lines: [String] = ["# \(document.title)", "", "_\(document.metadata.joined(separator: " · "))_"]
        for block in document.blocks {
            switch block {
            case .heading(let text, let level):
                lines += ["", String(repeating: "#", count: level + 1) + " " + text]
            case .paragraph(let text):
                lines += ["", text]
            case .bullets(let items):
                lines += [""] + items.map { "- \($0)" }
            case .chapters(let chapters):
                lines += [""] + chapters.enumerated().map { index, chapter in
                    let overview = chapter.overview.isEmpty ? "" : ": \(chapter.overview)"
                    return "\(index + 1). **\(chapter.title)** (\(chapter.range))\(overview)"
                }
            case .tasks(let tasks):
                lines += [""] + tasks.map { task in
                    "- [\(task.isDone ? "x" : " ")] \(task.text)" + (task.details.isEmpty ? "" : " (\(task.details))")
                }
            case .markedPassages(let passages):
                lines += [""] + passages.map { passage in
                    "- **\(passage.time)** \(passage.text ?? String(localized: "_Keine Sprache an dieser Stelle_", bundle: .module))"
                }
            case .transcript(let transcript):
                lines += [""] + transcript.map { line in
                    "[\(line.time)] \(line.speaker.map { "**\($0):** " } ?? "")\(line.text)\n"
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// A Markdown file for `ShareLink`. The text is rendered lazily when the user actually
/// shares, not every time the share menu is displayed.
public struct MarkdownDocument: Transferable, Sendable {
    let snapshot: MarkdownExporter.NoteSnapshot
    let options: MarkdownExporter.Options

    public init(snapshot: MarkdownExporter.NoteSnapshot, options: MarkdownExporter.Options) {
        self.snapshot = snapshot
        self.options = options
    }

    /// The note as Markdown text.
    public var text: String {
        MarkdownExporter().markdown(for: snapshot, options: options)
    }

    /// The content comes first: Mail, Messages, Notes and "Copy" take the text itself.
    /// Offering the file first made them insert a reference to a temporary file of the app
    /// instead of the note. Receivers that only accept files (Files, some AirDrop targets)
    /// still get a Markdown file.
    public static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.text)
        FileRepresentation(exportedContentType: .markdownText) { document in
            let url = FileManager.default.temporaryDirectory
                .appending(path: document.fileName, directoryHint: .notDirectory)
            try document.text.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }

    /// The file name for saving: the note's title without characters file systems reject.
    public var fileName: String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let base = snapshot.title.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return (base.isEmpty ? String(localized: "Notiz", bundle: .module) : base) + ".md"
    }
}

extension UTType {
    /// Markdown as declared by the system (`net.daringfireball.markdown`).
    public static let markdownText = UTType("net.daringfireball.markdown") ?? .plainText
}

extension MarkdownExporter.NoteSnapshot {
    /// Everything the export needs from a note; `segments` is the transcript the caller
    /// already decoded.
    ///
    /// A summary across several notes exports its notes instead of its source text, and the
    /// tasks of its notes without duplicates.
    @MainActor
    public init(note: Note, segments: [TranscriptSegment]) {
        let isCollection = note.kind == .collection
        let sourceNotes = isCollection ? note.sourceNotes() : []
        var summary = note.summary
        if isCollection {
            summary?.actionItems = CollectionTask.tasks(of: sourceNotes).map(\.item)
        }
        self.init(
            id: note.id,
            title: note.title,
            createdAt: note.createdAt,
            duration: note.duration,
            participants: note.participants,
            summary: summary,
            markers: note.markers,
            segments: segments,
            bodyText: isCollection ? "" : note.bodyText,
            audioSource: note.audioSourceDescription,
            keywords: note.summary?.keywords ?? [],
            labels: note.labels,
            sources: sourceNotes.map { "\($0.title) · \($0.createdAt.formatted(date: .abbreviated, time: .omitted))" }
        )
    }
}
