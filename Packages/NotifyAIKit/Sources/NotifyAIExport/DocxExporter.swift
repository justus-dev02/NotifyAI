//
//  DocxExporter.swift
//  NotifyAIExport
//

import Foundation
import NotifyAISupport

/// Writes an `ExportDocument` as a Word document (Office Open XML, `.docx`).
///
/// The document uses Word's own styles (Title, Heading 1/2, List Bullet), so headings appear
/// in the navigation pane and the user's style set applies. Bullets are a real list
/// (`numbering.xml`), not typed characters; tasks keep a check box symbol.
struct DocxExporter {
    func data(for document: ExportDocument, createdAt: Date = .now) -> Data {
        var archive = ZipArchive(date: createdAt)
        archive.add("[Content_Types].xml", Self.contentTypes)
        archive.add("_rels/.rels", Self.packageRelationships)
        archive.add("docProps/core.xml", Self.coreProperties(title: document.title, createdAt: createdAt))
        archive.add("word/_rels/document.xml.rels", Self.documentRelationships)
        archive.add("word/styles.xml", Self.styles)
        archive.add("word/numbering.xml", Self.numbering)
        archive.add("word/document.xml", Self.body(of: document))
        return archive.finished()
    }

    // MARK: - Body

    static func body(of document: ExportDocument) -> String {
        var paragraphs = [paragraph(style: "Title", runs: [run(document.title)])]
        paragraphs.append(paragraph(style: "Subtitle", runs: [run(document.metadata.joined(separator: " · "))]))
        for block in document.blocks {
            switch block {
            case .heading(let title, let level):
                paragraphs.append(paragraph(style: level == 1 ? "Heading1" : "Heading2", runs: [run(title)]))
            case .paragraph(let text):
                // Line breaks inside a text become separate paragraphs.
                paragraphs += text.components(separatedBy: "\n").map { paragraph(runs: [run($0)]) }
            case .bullets(let items):
                paragraphs += items.map { paragraph(style: "ListBullet", list: true, runs: [run($0)]) }
            case .chapters(let chapters):
                paragraphs += chapters.enumerated().map { index, chapter in
                    let overview = chapter.overview.isEmpty ? "" : " – \(chapter.overview)"
                    return paragraph(runs: [run("\(index + 1). \(chapter.title)", bold: true), run("  \(chapter.range)\(overview)")])
                }
            case .tasks(let tasks):
                paragraphs += tasks.map { task in
                    var runs = [run("\(task.isDone ? "☑" : "☐")  \(task.text)")]
                    if !task.details.isEmpty { runs.append(run("  (\(task.details))", color: "666666")) }
                    return paragraph(runs: runs)
                }
            case .markedPassages(let passages):
                paragraphs += passages.map { passage in
                    paragraph(runs: [
                        run(passage.time + "  ", bold: true),
                        run(passage.text ?? String(localized: "Keine Sprache an dieser Stelle", bundle: .module)),
                    ])
                }
            case .transcript(let lines):
                paragraphs += lines.map { line in
                    var runs = [run(line.time + "  ", color: "777777")]
                    if let speaker = line.speaker { runs.append(run(speaker + ": ", bold: true)) }
                    runs.append(run(line.text))
                    return paragraph(runs: runs)
                }
            }
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(paragraphs.joined())\
        <w:sectPr><w:pgSz w:w="11906" w:h="16838"/>\
        <w:pgMar w:top="1418" w:right="1418" w:bottom="1418" w:left="1418" w:header="709" w:footer="709" w:gutter="0"/></w:sectPr>\
        </w:body></w:document>
        """
    }

    private static func paragraph(style: String? = nil, list: Bool = false, runs: [String]) -> String {
        var properties = ""
        if let style { properties += #"<w:pStyle w:val="\#(style)"/>"# }
        if list { properties += #"<w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr>"# }
        let paragraphProperties = properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>"
        return "<w:p>\(paragraphProperties)\(runs.joined())</w:p>"
    }

    private static func run(_ text: String, bold: Bool = false, color: String? = nil) -> String {
        var properties = ""
        if bold { properties += "<w:b/>" }
        if let color { properties += #"<w:color w:val="\#(color)"/>"# }
        let runProperties = properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>"
        return #"<w:r>\#(runProperties)<w:t xml:space="preserve">\#(escaped(text))</w:t></w:r>"#
    }

    /// XML text content: markup characters escaped, characters XML 1.0 forbids removed.
    static func escaped(_ text: String) -> String {
        let allowed = text.unicodeScalars.filter { scalar in
            scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar.value >= 0x20 && scalar.value != 0xFFFE && scalar.value != 0xFFFF
        }
        return String(String.UnicodeScalarView(allowed))
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Package parts

    private static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
    <Default Extension="xml" ContentType="application/xml"/>\
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
    <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
    <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>\
    <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
    </Types>
    """

    private static let packageRelationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
    </Relationships>
    """

    private static let documentRelationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>\
    </Relationships>
    """

    private static func coreProperties(title: String, createdAt: Date) -> String {
        let date = createdAt.formatted(.iso8601)
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\
        <dc:title>\(escaped(title))</dc:title><dc:creator>NotifyAI</dc:creator>\
        <dcterms:created xsi:type="dcterms:W3CDTF">\(date)</dcterms:created>\
        </cp:coreProperties>
        """
    }

    private static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
    <w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val="22"/></w:rPr></w:rPrDefault>\
    <w:pPrDefault><w:pPr><w:spacing w:after="80" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>\
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>\
    <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/>\
    <w:pPr><w:spacing w:after="60"/></w:pPr><w:rPr><w:b/><w:sz w:val="44"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/>\
    <w:pPr><w:spacing w:after="240"/></w:pPr><w:rPr><w:color w:val="666666"/><w:sz w:val="20"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/>\
    <w:pPr><w:keepNext/><w:spacing w:before="280" w:after="80"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="30"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/>\
    <w:pPr><w:keepNext/><w:spacing w:before="160" w:after="40"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="24"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="ListBullet"><w:name w:val="List Bullet"/><w:basedOn w:val="Normal"/>\
    <w:pPr><w:numPr><w:numId w:val="1"/></w:numPr><w:spacing w:after="40"/></w:pPr></w:style>\
    </w:styles>
    """

    private static let numbering = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
    <w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="singleLevel"/>\
    <w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/><w:lvlJc w:val="left"/>\
    <w:pPr><w:ind w:left="360" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>\
    <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>\
    </w:numbering>
    """
}
