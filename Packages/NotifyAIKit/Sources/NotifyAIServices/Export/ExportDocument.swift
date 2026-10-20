//
//  ExportDocument.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore

/// A note as a structured document: the single description of what an export contains.
///
/// Markdown, PDF, Word, Notion and the Obsidian folder all render this document, so every
/// format has the same sections in the same order with the same texts. Personal data is
/// redacted here, once, when the options ask for it.
public struct ExportDocument: Equatable, Sendable {
    public struct Chapter: Equatable, Sendable {
        let title: String
        /// "00:00–10:00"
        let range: String
        let overview: String
    }

    public struct Task: Equatable, Sendable {
        let text: String
        /// "Eddy, bis Freitag"; empty without owner and deadline.
        let details: String
        let isDone: Bool
    }

    public struct MarkedPassage: Equatable, Sendable {
        let time: String
        /// `nil` when nothing was said at that moment.
        let text: String?
    }

    public struct Line: Equatable, Sendable {
        let time: String
        let speaker: String?
        let text: String
    }

    public enum Block: Equatable, Sendable {
        /// Level 1: a section ("Überblick"); level 2: a part of a section (a topic).
        case heading(String, level: Int)
        case paragraph(String)
        case bullets([String])
        case chapters([Chapter])
        case tasks([Task])
        case markedPassages([MarkedPassage])
        case transcript([Line])
    }

    public let title: String
    /// Date, duration, audio source and participants.
    public let metadata: [String]
    public let blocks: [Block]

    init(title: String, metadata: [String], blocks: [Block]) {
        self.title = title
        self.metadata = metadata
        self.blocks = blocks
    }

    public init(note: MarkdownExporter.NoteSnapshot, options: MarkdownExporter.Options = .init()) {
        var blocks: [Block] = []
        if let summary = note.summary {
            blocks += Self.summaryBlocks(summary)
        }
        if !note.sources.isEmpty {
            blocks += [.heading(String(localized: "Zusammengefasste Notizen", bundle: .module), level: 1), .bullets(note.sources)]
        }
        blocks += Self.markerBlocks(of: note)
        if options.includesTranscript {
            blocks += Self.textBlocks(of: note)
        }
        let document = Self(title: note.title, metadata: Self.metadata(of: note), blocks: blocks)
        self = options.redactsPersonalData ? document.redacted() : document
    }

    // MARK: - Sections

    private static func metadata(of note: MarkdownExporter.NoteSnapshot) -> [String] {
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
        if !note.labels.isEmpty {
            metadata.append(String(localized: "Labels: \(note.labels.joined(separator: ", "))", bundle: .module))
        }
        return metadata
    }

    private static func summaryBlocks(_ summary: NoteSummary) -> [Block] {
        var blocks: [Block] = [.heading(String(localized: "Überblick", bundle: .module), level: 1), .paragraph(summary.overview)]
        if !summary.chapters.isEmpty {
            blocks.append(.heading(String(localized: "Kapitel", bundle: .module), level: 1))
            blocks.append(.chapters(summary.chapters.map { chapter in
                Chapter(
                    title: chapter.title,
                    range: "\(TimeFormatting.timestamp(chapter.start))–\(TimeFormatting.timestamp(chapter.end))",
                    overview: chapter.overview
                )
            }))
        }
        blocks += list(String(localized: "Kernpunkte", bundle: .module), summary.keyPoints)
        for section in summary.templateSections {
            blocks += list(section.title, section.points)
        }
        blocks += list(String(localized: "Entscheidungen", bundle: .module), summary.decisions)
        if !summary.actionItems.isEmpty {
            blocks.append(.heading(String(localized: "Aufgaben", bundle: .module), level: 1))
            blocks.append(.tasks(summary.actionItems.map { item in
                let details = [item.owner, item.due.map { String(localized: "bis \($0)", bundle: .module) }].compactMap { $0 }
                return Task(text: item.task, details: details.joined(separator: ", "), isDone: item.isDone)
            }))
        }
        blocks += list(String(localized: "Offene Fragen", bundle: .module), summary.openQuestions)
        if !summary.topics.isEmpty {
            blocks.append(.heading(String(localized: "Themen", bundle: .module), level: 1))
            for topic in summary.topics {
                blocks.append(.heading(topic.title, level: 2))
                blocks.append(.bullets(topic.points))
            }
        }
        return blocks
    }

    private static func markerBlocks(of note: MarkdownExporter.NoteSnapshot) -> [Block] {
        guard !note.markers.isEmpty else { return [] }
        let passages = note.markers.map { marker in
            let text = Transcript.text(in: marker.highlightRange(duration: note.duration), of: note.segments)
            return MarkedPassage(time: TimeFormatting.timestamp(marker.time), text: text.isEmpty ? nil : text)
        }
        return [.heading(String(localized: "Markierte Stellen", bundle: .module), level: 1), .markedPassages(passages)]
    }

    private static func textBlocks(of note: MarkdownExporter.NoteSnapshot) -> [Block] {
        if !note.segments.isEmpty {
            let lines = note.segments.map { Line(time: TimeFormatting.timestamp($0.start), speaker: $0.speaker, text: $0.text) }
            return [.heading(String(localized: "Transkript", bundle: .module), level: 1), .transcript(lines)]
        }
        guard !note.bodyText.isEmpty else { return [] }
        return [.heading(String(localized: "Text", bundle: .module), level: 1), .paragraph(note.bodyText)]
    }

    private static func list(_ title: String, _ items: [String]) -> [Block] {
        items.isEmpty ? [] : [.heading(title, level: 1), .bullets(items)]
    }

    // MARK: - Redaction

    /// Every text with e-mail addresses, phone numbers and IBANs replaced.
    func redacted() -> Self {
        let redact = Redactor.redact
        return Self(
            title: redact(title),
            metadata: metadata.map(redact),
            blocks: blocks.map { block in
                switch block {
                case .heading(let text, let level): .heading(redact(text), level: level)
                case .paragraph(let text): .paragraph(redact(text))
                case .bullets(let items): .bullets(items.map(redact))
                case .chapters(let chapters):
                    .chapters(chapters.map { Chapter(title: redact($0.title), range: $0.range, overview: redact($0.overview)) })
                case .tasks(let tasks):
                    .tasks(tasks.map { Task(text: redact($0.text), details: redact($0.details), isDone: $0.isDone) })
                case .markedPassages(let passages):
                    .markedPassages(passages.map { MarkedPassage(time: $0.time, text: $0.text.map(redact)) })
                case .transcript(let lines):
                    .transcript(lines.map { Line(time: $0.time, speaker: $0.speaker.map(redact), text: redact($0.text)) })
                }
            }
        )
    }
}
