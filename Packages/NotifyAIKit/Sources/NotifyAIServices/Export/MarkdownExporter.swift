//
//  MarkdownExporter.swift
//  NotifyAIServices
//

import CoreTransferable
import Foundation
import NotifyAICore
import NotifyAIPersistence
import UniformTypeIdentifiers

/// Renders a note as Markdown for sharing.
public struct MarkdownExporter {
    public struct Options: Sendable {
        var includesTranscript = true
        /// Replaces e-mail addresses, phone numbers and IBANs.
        var redactsPersonalData = false

        public init(includesTranscript: Bool = true, redactsPersonalData: Bool = false) {
            self.includesTranscript = includesTranscript
            self.redactsPersonalData = redactsPersonalData
        }
    }

    public struct NoteSnapshot: Sendable {
        var title: String
        var createdAt: Date
        var duration: TimeInterval
        var participants: [String]
        var summary: NoteSummary?
        var markers: [Marker]
        var segments: [TranscriptSegment]
        var bodyText: String
        /// "Mikrofon + Zoom" etc.; `nil` for microphone recordings and imports.
        var audioSource: String?
    }

    func markdown(for note: NoteSnapshot, options: Options = Options()) -> String {
        var lines: [String] = ["# \(note.title)", "", "_\(metadata(of: note).joined(separator: " · "))_"]
        if let summary = note.summary {
            lines += summarySection(summary)
        }
        lines += markerSection(of: note)
        if options.includesTranscript {
            lines += textSection(of: note)
        }
        let markdown = lines.joined(separator: "\n") + "\n"
        return options.redactsPersonalData ? Redactor.redact(markdown) : markdown
    }

    // MARK: - Sections

    private func metadata(of note: NoteSnapshot) -> [String] {
        var metadata = [note.createdAt.formatted(date: .long, time: .shortened)]
        if note.duration > 0 {
            metadata.append(TimeFormatting.duration(note.duration))
        }
        if let audioSource = note.audioSource {
            metadata.append(audioSource)
        }
        if !note.participants.isEmpty {
            metadata.append(String(localized: "Teilnehmende: \(note.participants.joined(separator: ", "))", bundle: .module))
        }
        return metadata
    }

    private func summarySection(_ summary: NoteSummary) -> [String] {
        var lines = ["", String(localized: "## Überblick", bundle: .module), "", summary.overview]
        if !summary.chapters.isEmpty {
            lines += ["", String(localized: "## Kapitel", bundle: .module), ""]
            lines += summary.chapters.enumerated().map { index, chapter in
                let range = "\(TimeFormatting.timestamp(chapter.start))–\(TimeFormatting.timestamp(chapter.end))"
                let overview = chapter.overview.isEmpty ? "" : ": \(chapter.overview)"
                return "\(index + 1). **\(chapter.title)** (\(range))\(overview)"
            }
        }
        appendList(String(localized: "Kernpunkte", bundle: .module), summary.keyPoints, to: &lines)
        appendList(String(localized: "Entscheidungen", bundle: .module), summary.decisions, to: &lines)
        if !summary.actionItems.isEmpty {
            lines += ["", String(localized: "## Aufgaben", bundle: .module), ""]
            lines += summary.actionItems.map { item in
                var line = "- [\(item.isDone ? "x" : " ")] \(item.task)"
                let details = [item.owner, item.due.map { String(localized: "bis \($0)", bundle: .module) }].compactMap { $0 }
                if !details.isEmpty { line += " (\(details.joined(separator: ", ")))" }
                return line
            }
        }
        appendList(String(localized: "Offene Fragen", bundle: .module), summary.openQuestions, to: &lines)
        if !summary.topics.isEmpty {
            lines += ["", String(localized: "## Themen", bundle: .module)]
            for topic in summary.topics {
                lines += ["", "### \(topic.title)", ""]
                lines += topic.points.map { "- \($0)" }
            }
        }
        return lines
    }

    private func markerSection(of note: NoteSnapshot) -> [String] {
        guard !note.markers.isEmpty else { return [] }
        return ["", String(localized: "## Markierte Stellen", bundle: .module), ""] + note.markers.map { marker in
            let text = Transcript.text(in: marker.highlightRange(duration: note.duration), of: note.segments)
            let passage = text.isEmpty ? String(localized: "_Keine Sprache an dieser Stelle_", bundle: .module) : text
            return "- **\(TimeFormatting.timestamp(marker.time))** \(passage)"
        }
    }

    private func textSection(of note: NoteSnapshot) -> [String] {
        if !note.segments.isEmpty {
            return ["", String(localized: "## Transkript", bundle: .module), ""] + note.segments.map { segment in
                let speaker = segment.speaker.map { "**\($0):** " } ?? ""
                return "[\(TimeFormatting.timestamp(segment.start))] \(speaker)\(segment.text)\n"
            }
        }
        guard !note.bodyText.isEmpty else { return [] }
        return ["", String(localized: "## Text", bundle: .module), "", note.bodyText]
    }

    private func appendList(_ title: String, _ items: [String], to lines: inout [String]) {
        guard !items.isEmpty else { return }
        lines += ["", "## \(title)", ""]
        lines += items.map { "- \($0)" }
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
    public init(note: Note, segments: [TranscriptSegment]) {
        self.init(
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
    }
}
