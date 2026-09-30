//
//  MarkdownExporter.swift
//  NotifyAI
//

import CoreTransferable
import Foundation
import NotifyAICore
import UniformTypeIdentifiers

/// Renders a note as Markdown for sharing.
struct MarkdownExporter {
    struct Options: Sendable {
        var includesTranscript = true
        /// Replaces e-mail addresses, phone numbers and IBANs.
        var redactsPersonalData = false
    }

    struct NoteSnapshot: Sendable {
        var title: String
        var createdAt: Date
        var duration: TimeInterval
        var participants: [String]
        var summary: NoteSummary?
        var markers: [Marker]
        var segments: [TranscriptSegment]
        var bodyText: String
        /// "Mikrofon + Zoom" etc.; `nil` for microphone recordings and imports.
        var audioSource: String? = nil
    }

    func markdown(for note: NoteSnapshot, options: Options = Options()) -> String {
        var lines: [String] = ["# \(note.title)", ""]

        var metadata = [note.createdAt.formatted(date: .long, time: .shortened)]
        if note.duration > 0 {
            metadata.append(TimeFormatting.duration(note.duration))
        }
        if let audioSource = note.audioSource {
            metadata.append(audioSource)
        }
        if !note.participants.isEmpty {
            metadata.append(String(localized: "Teilnehmende: \(note.participants.joined(separator: ", "))"))
        }
        lines.append("_\(metadata.joined(separator: " · "))_")

        if let summary = note.summary {
            lines += ["", String(localized: "## Überblick"), "", summary.overview]
            if !summary.chapters.isEmpty {
                lines += ["", String(localized: "## Kapitel"), ""]
                lines += summary.chapters.enumerated().map { index, chapter in
                    let range = "\(TimeFormatting.timestamp(chapter.start))–\(TimeFormatting.timestamp(chapter.end))"
                    let overview = chapter.overview.isEmpty ? "" : ": \(chapter.overview)"
                    return "\(index + 1). **\(chapter.title)** (\(range))\(overview)"
                }
            }
            appendList(String(localized: "Kernpunkte"), summary.keyPoints, to: &lines)
            appendList(String(localized: "Entscheidungen"), summary.decisions, to: &lines)
            if !summary.actionItems.isEmpty {
                lines += ["", String(localized: "## Aufgaben"), ""]
                lines += summary.actionItems.map { item in
                    var line = "- [\(item.isDone ? "x" : " ")] \(item.task)"
                    let details = [item.owner, item.due.map { String(localized: "bis \($0)") }].compactMap { $0 }
                    if !details.isEmpty { line += " (\(details.joined(separator: ", ")))" }
                    return line
                }
            }
            appendList(String(localized: "Offene Fragen"), summary.openQuestions, to: &lines)
            if !summary.topics.isEmpty {
                lines += ["", String(localized: "## Themen")]
                for topic in summary.topics {
                    lines += ["", "### \(topic.title)", ""]
                    lines += topic.points.map { "- \($0)" }
                }
            }
        }

        if !note.markers.isEmpty {
            lines += ["", String(localized: "## Markierte Stellen"), ""]
            lines += note.markers.map { marker in
                let text = Transcript.text(in: marker.highlightRange(duration: note.duration), of: note.segments)
                return "- **\(TimeFormatting.timestamp(marker.time))** \(text)"
            }
        }

        if options.includesTranscript {
            if !note.segments.isEmpty {
                lines += ["", String(localized: "## Transkript"), ""]
                lines += note.segments.map { segment in
                    let speaker = segment.speaker.map { "**\($0):** " } ?? ""
                    return "[\(TimeFormatting.timestamp(segment.start))] \(speaker)\(segment.text)\n"
                }
            } else if !note.bodyText.isEmpty {
                lines += ["", String(localized: "## Text"), "", note.bodyText]
            }
        }

        let markdown = lines.joined(separator: "\n") + "\n"
        return options.redactsPersonalData ? Redactor.redact(markdown) : markdown
    }

    private func appendList(_ title: String, _ items: [String], to lines: inout [String]) {
        guard !items.isEmpty else { return }
        lines += ["", "## \(title)", ""]
        lines += items.map { "- \($0)" }
    }
}

/// A Markdown file for `ShareLink`. The text is rendered lazily when the user actually
/// shares, not every time the share menu is displayed.
struct MarkdownDocument: Transferable, Sendable {
    let snapshot: MarkdownExporter.NoteSnapshot
    let options: MarkdownExporter.Options

    var text: String {
        MarkdownExporter().markdown(for: snapshot, options: options)
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .markdownText) { document in
            let url = FileManager.default.temporaryDirectory
                .appending(path: document.fileName, directoryHint: .notDirectory)
            try document.text.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
        DataRepresentation(exportedContentType: .plainText) { document in
            Data(document.text.utf8)
        }
    }

    private var fileName: String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let base = snapshot.title.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return (base.isEmpty ? String(localized: "Notiz") : base) + ".md"
    }
}

extension UTType {
    /// Markdown as declared by the system (`net.daringfireball.markdown`).
    static let markdownText = UTType("net.daringfireball.markdown") ?? .plainText
}
