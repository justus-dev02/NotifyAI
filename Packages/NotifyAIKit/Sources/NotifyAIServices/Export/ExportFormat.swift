//
//  ExportFormat.swift
//  NotifyAIServices
//

import CoreTransferable
import Foundation
import NotifyAICore
import UniformTypeIdentifiers

/// The file formats a note can be exported in.
public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case markdown
    case pdf
    case word
    case subRip
    case webVTT

    public var id: String { rawValue }

    /// Product and format names; they are not translated.
    public var title: String {
        switch self {
        case .markdown: "Markdown"
        case .pdf: "PDF"
        case .word: "Word"
        case .subRip: "SRT"
        case .webVTT: "WebVTT"
        }
    }

    public var symbolName: String {
        switch self {
        case .markdown: "doc.text"
        case .pdf: "doc.richtext"
        case .word: "doc"
        case .subRip, .webVTT: "captions.bubble"
        }
    }

    public var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .pdf: "pdf"
        case .word: "docx"
        case .subRip: "srt"
        case .webVTT: "vtt"
        }
    }

    public var contentType: UTType {
        switch self {
        case .markdown: .markdownText
        case .pdf: .pdf
        case .word: UTType("org.openxmlformats.wordprocessingml.document") ?? UTType(filenameExtension: "docx") ?? .data
        case .subRip: UTType(filenameExtension: "srt", conformingTo: .plainText) ?? .plainText
        case .webVTT: UTType("org.w3.webvtt") ?? UTType(filenameExtension: "vtt", conformingTo: .plainText) ?? .plainText
        }
    }

    /// Subtitles need a transcript with times.
    public var needsTranscript: Bool {
        self == .subRip || self == .webVTT
    }

    func data(for snapshot: MarkdownExporter.NoteSnapshot, options: MarkdownExporter.Options) -> Data {
        switch self {
        case .markdown:
            Data(MarkdownExporter().markdown(for: snapshot, options: options).utf8)
        case .pdf:
            PDFExporter().data(for: ExportDocument(note: snapshot, options: options))
        case .word:
            DocxExporter().data(for: ExportDocument(note: snapshot, options: options), createdAt: snapshot.createdAt)
        case .subRip, .webVTT:
            Data(subtitles(for: snapshot, options: options).utf8)
        }
    }

    private func subtitles(for snapshot: MarkdownExporter.NoteSnapshot, options: MarkdownExporter.Options) -> String {
        var segments = snapshot.segments
        if options.redactsPersonalData {
            segments = segments.map { segment in
                var segment = segment
                segment.text = Redactor.redact(segment.text)
                segment.words = segment.words.map { TranscriptWord(text: Redactor.redact($0.text), start: $0.start, end: $0.end) }
                return segment
            }
        }
        return SubtitleExporter().render(segments, as: self == .subRip ? .subRip : .webVTT)
    }
}

/// A note in one export format, rendered when it is actually shared or saved.
public struct ExportedFile: Transferable, Sendable {
    let snapshot: MarkdownExporter.NoteSnapshot
    let options: MarkdownExporter.Options
    public let format: ExportFormat

    public init(snapshot: MarkdownExporter.NoteSnapshot, options: MarkdownExporter.Options, format: ExportFormat) {
        self.snapshot = snapshot
        self.options = options
        self.format = format
    }

    public var data: Data {
        format.data(for: snapshot, options: options)
    }

    /// The note's title without characters file systems reject, with the format's extension.
    public var fileName: String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let base = snapshot.title.components(separatedBy: invalid).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return (base.isEmpty ? String(localized: "Notiz", bundle: .module) : base) + "." + format.fileExtension
    }

    /// One representation per format, with its exact type, so Mail, Files and Word recognize
    /// the file.
    public static var transferRepresentation: some TransferRepresentation {
        representation(for: .markdown)
        representation(for: .pdf)
        representation(for: .word)
        representation(for: .subRip)
        representation(for: .webVTT)
    }

    private static func representation(for format: ExportFormat) -> some TransferRepresentation<Self> {
        FileRepresentation(exportedContentType: format.contentType) { file in
            SentTransferredFile(try file.writeTemporaryFile())
        }
        .exportingCondition { $0.format == format }
    }

    /// Writes the file into its own temporary folder, so its name can be the note's title.
    func writeTemporaryFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: fileName, directoryHint: .notDirectory)
        try data.write(to: url)
        return url
    }
}
