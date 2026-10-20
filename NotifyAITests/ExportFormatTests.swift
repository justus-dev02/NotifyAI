//
//  ExportFormatTests.swift
//  NotifyAITests
//
//  PDF, Word and subtitles of the golden note: valid files with the complete content.
//

import Foundation
@testable import NotifyAI
import NotifyAICore
@testable import NotifyAIServices
import PDFKit
import Testing

/// Reads the entries of a ZIP archive with stored entries and checks their CRC.
enum StoredZip {
    struct Entry {
        let name: String
        let data: Data
    }

    static func entries(of archive: Data) throws -> [Entry] {
        var entries: [Entry] = []
        var offset = 0
        let bytes = [UInt8](archive)
        func le16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func le32(_ at: Int) -> UInt32 { UInt32(le16(at)) | UInt32(le16(at + 2)) << 16 }
        while offset + 30 <= bytes.count, le32(offset) == 0x0403_4B50 {
            #expect(le16(offset + 8) == 0, "Entries are stored")
            let crc = le32(offset + 14)
            let size = Int(le32(offset + 18))
            let nameLength = le16(offset + 26)
            let extraLength = le16(offset + 28)
            let nameStart = offset + 30
            let dataStart = nameStart + nameLength + extraLength
            let name = String(bytes: bytes[nameStart..<(nameStart + nameLength)], encoding: .utf8) ?? ""
            let data = Data(bytes[dataStart..<(dataStart + size)])
            #expect(ZipArchive.crc32(data) == crc, "CRC of \(name)")
            entries.append(Entry(name: name, data: data))
            offset = dataStart + size
        }
        // The central directory follows and lists every entry.
        #expect(le32(offset) == 0x0201_4B50)
        return entries
    }
}

@Suite("Export formats")
struct ExportFormatTests {
    let snapshot = ExportFixture.snapshot

    @Test("CRC-32 matches the reference value")
    func crc() {
        #expect(ZipArchive.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test("Word: a valid package with every part and the note's content as well-formed XML")
    func word() throws {
        let data = ExportFormat.word.data(for: snapshot, options: .init())
        let entries = try StoredZip.entries(of: data)
        let names = Set(entries.map(\.name))
        let expected: Set = [
            "[Content_Types].xml", "_rels/.rels", "docProps/core.xml", "word/_rels/document.xml.rels",
            "word/styles.xml", "word/numbering.xml", "word/document.xml",
        ]
        #expect(names == expected)
        for entry in entries {
            let parser = XMLParser(data: entry.data)
            #expect(parser.parse(), "\(entry.name) is not well-formed: \(parser.parserError?.localizedDescription ?? "")")
        }
        let document = try #require(entries.first { $0.name == "word/document.xml" }).data
        let xml = String(bytes: document, encoding: .utf8) ?? ""
        let texts = ["Weekly: Relaunch", "Überblick", "Budget 18.000 Euro", "Risiken", "☑  Texte schreiben", "Wer pflegt die Seite?", "Dann machen wir das so."]
        for text in texts {
            #expect(xml.contains(text), "Missing: \(text)")
        }
        #expect(xml.contains(#"<w:pStyle w:val="Heading1"/>"#))
        #expect(xml.contains(#"<w:numId w:val="1"/>"#))
    }

    @Test("Word escapes markup and drops characters XML forbids")
    func wordEscaping() {
        #expect(DocxExporter.escaped("A & B <c> \"d\"\u{0007}") == "A &amp; B &lt;c&gt; &quot;d&quot;")
    }

    @Test("PDF: readable, A4, with title and transcript, over several pages for long notes")
    func pdf() throws {
        let data = ExportFormat.pdf.data(for: snapshot, options: .init())
        let document = try #require(PDFDocument(data: data))
        // A short note: one or two pages.
        #expect((1...2).contains(document.pageCount))
        let page = try #require(document.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)
        #expect(abs(bounds.width - 595.28) < 1 && abs(bounds.height - 841.89) < 1)
        let text = document.string ?? ""
        for expected in ["Weekly: Relaunch", "Budget 18.000 Euro", "Texte schreiben", "Dann machen wir das so."] {
            #expect(text.contains(expected), "Missing: \(expected)")
        }

        var long = snapshot
        long.segments = (0..<400).map { TranscriptSegment(start: Double($0 * 5), end: Double($0 * 5 + 4), text: "Satz Nummer \($0) im langen Gespräch.") }
        let longDocument = try #require(PDFDocument(data: ExportFormat.pdf.data(for: long, options: .init())))
        #expect(longDocument.pageCount > 5)
        #expect(longDocument.string?.contains("Satz Nummer 399") == true)
    }

    @Test("Redaction applies to the files as well")
    func redactedFiles() throws {
        let options = MarkdownExporter.Options(redactsPersonalData: true)
        let word = try StoredZip.entries(of: ExportFormat.word.data(for: snapshot, options: options))
        let xml = String(bytes: try #require(word.first { $0.name == "word/document.xml" }).data, encoding: .utf8) ?? ""
        #expect(!xml.contains("max@example.com"))
        let subtitles = String(bytes: ExportFormat.subRip.data(for: snapshot, options: options), encoding: .utf8) ?? ""
        #expect(!subtitles.contains("max@example.com"))
    }

    @Test("File names come from the title with the format's extension")
    func fileNames() {
        let file = ExportedFile(snapshot: snapshot, options: .init(), format: .word)
        #expect(file.fileName == "Weekly- Relaunch.docx")
        #expect(ExportedFile(snapshot: snapshot, options: .init(), format: .webVTT).fileName.hasSuffix(".vtt"))
    }
}

@Suite("Subtitles")
struct SubtitleTests {
    @Test("SRT: numbered cues, comma milliseconds, speaker at a change")
    func subRip() {
        let srt = SubtitleExporter().render(ExportFixture.snapshot.segments, as: .subRip)
        #expect(srt.hasPrefix("1\n00:00:01,000 --> 00:00:04,000\nAnna: Guten Morgen zusammen.\n"))
        #expect(srt.contains("\n2\n00:00:04,000 --> "))
        #expect(srt.contains("Eddy: Ich habe"))
    }

    @Test("WebVTT: header, dot milliseconds, voice tags")
    func webVTT() {
        let vtt = SubtitleExporter().render(ExportFixture.snapshot.segments, as: .webVTT)
        #expect(vtt.hasPrefix("WEBVTT\n\n00:00:01.000 --> 00:00:04.000\n<v Anna>Guten Morgen zusammen.\n"))
        #expect(vtt.contains("<v Eddy>"))
    }

    @Test("Long segments become readable cues: two lines, at most seven seconds, no overlap")
    func readableCues() {
        let words = (0..<60).map { index in
            TranscriptWord(text: (index == 0 ? "" : " ") + "Wort\(index)", start: Double(index) * 0.4, end: Double(index) * 0.4 + 0.35)
        }
        let segment = TranscriptSegment(start: 0, end: 24, text: words.map(\.text).joined(), words: words)
        let cues = SubtitleExporter().cues(for: [segment])
        #expect(cues.count > 3)
        for cue in cues {
            #expect(cue.lines.count <= 2)
            #expect(cue.lines.joined(separator: " ").count <= 2 * SubtitleExporter.maximumLineLength)
            #expect(cue.end - cue.start <= SubtitleExporter.maximumDuration + 0.4)
        }
        for (current, next) in zip(cues, cues.dropFirst()) {
            #expect(current.end <= next.start)
        }
        // Every word appears exactly once.
        #expect(cues.flatMap { $0.lines.joined(separator: " ").split(separator: " ") }.count == 60)
    }

    @Test("Timestamps over an hour")
    func longTimestamps() {
        #expect(SubtitleExporter.timestamp(3_723.456, separator: ",") == "01:02:03,456")
    }
}
