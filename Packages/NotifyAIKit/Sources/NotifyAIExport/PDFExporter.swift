//
//  PDFExporter.swift
//  NotifyAIExport
//

import CoreGraphics
import CoreText
import Foundation
import NotifyAISupport

/// Typesets an `ExportDocument` as an A4 PDF with Core Text: the same on iOS and macOS, no
/// web view, no UIKit or AppKit. Text flows from page to page; every page has a footer with
/// the title and the page number.
struct PDFExporter {
    /// A4 in points.
    static let pageSize = CGSize(width: 595.28, height: 841.89)
    static let margin: CGFloat = 56
    static let footerHeight: CGFloat = 24

    func data(for document: ExportDocument) -> Data {
        let text = Self.attributedText(for: document)
        let output = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: Self.pageSize)
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else { return Data() }
        let info = [kCGPDFContextTitle as String: document.title, kCGPDFContextCreator as String: "NotifyAI"] as CFDictionary
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info) else { return Data() }

        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let textRect = CGRect(
            x: Self.margin,
            y: Self.margin + Self.footerHeight,
            width: Self.pageSize.width - 2 * Self.margin,
            height: Self.pageSize.height - 2 * Self.margin - Self.footerHeight
        )
        var position = 0
        var page = 1
        repeat {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: position, length: 0), CGPath(rect: textRect, transform: nil), nil)
            CTFrameDraw(frame, context)
            drawFooter(title: document.title, page: page, in: context)
            context.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            // A frame that fits nothing (cannot happen with text at these sizes) would loop forever.
            guard visible.length > 0 else { break }
            position += visible.length
            page += 1
        } while position < text.length
        context.closePDF()
        return output as Data
    }

    private func drawFooter(title: String, page: Int, in context: CGContext) {
        let footer = NSAttributedString(string: "\(title) · \(page)", attributes: Self.attributes(.footer))
        let line = CTLineCreateWithAttributedString(footer)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(x: (Self.pageSize.width - width) / 2, y: Self.margin / 2)
        CTLineDraw(line, context)
    }

    // MARK: - Text

    enum Style {
        case title, metadata, heading, subheading, body, bold, secondary, footer
    }

    static func attributedText(for document: ExportDocument) -> NSAttributedString {
        let text = NSMutableAttributedString()
        func append(_ string: String, _ style: Style) {
            text.append(NSAttributedString(string: string, attributes: attributes(style)))
        }
        append(document.title + "\n", .title)
        append(document.metadata.joined(separator: " · ") + "\n", .metadata)
        for block in document.blocks {
            switch block {
            case .heading(let title, let level):
                append(title + "\n", level == 1 ? .heading : .subheading)
            case .paragraph(let paragraph):
                append(paragraph + "\n", .body)
            case .bullets(let items):
                for item in items { append("•  \(item)\n", .body) }
            case .chapters(let chapters):
                for (index, chapter) in chapters.enumerated() {
                    append("\(index + 1). \(chapter.title)", .bold)
                    append("  \(chapter.range)\(chapter.overview.isEmpty ? "" : " – \(chapter.overview)")\n", .body)
                }
            case .tasks(let tasks):
                for task in tasks {
                    append("\(task.isDone ? "☑" : "☐")  \(task.text)", .body)
                    append(task.details.isEmpty ? "\n" : "  (\(task.details))\n", .secondary)
                }
            case .markedPassages(let passages):
                for passage in passages {
                    append(passage.time + "  ", .bold)
                    append((passage.text ?? String(localized: "Keine Sprache an dieser Stelle", bundle: .module)) + "\n", .body)
                }
            case .transcript(let lines):
                for line in lines {
                    append(line.time + "  ", .secondary)
                    if let speaker = line.speaker { append(speaker + ": ", .bold) }
                    append(line.text + "\n", .body)
                }
            }
        }
        return text
    }

    static func attributes(_ style: Style) -> [NSAttributedString.Key: Any] {
        let (size, weight, gray, spacingBefore, spacingAfter): (CGFloat, CTFontUIFontType, CGFloat, CGFloat, CGFloat) = switch style {
        case .title: (22, .emphasizedSystem, 0, 0, 4)
        case .metadata: (10, .system, 0.4, 0, 14)
        case .heading: (14, .emphasizedSystem, 0, 14, 4)
        case .subheading: (12, .emphasizedSystem, 0.15, 8, 2)
        case .body: (11, .system, 0, 0, 3)
        case .bold: (11, .emphasizedSystem, 0, 0, 3)
        case .secondary: (10, .system, 0.45, 0, 3)
        case .footer: (8, .system, 0.5, 0, 0)
        }
        let font = CTFontCreateUIFontForLanguage(weight, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let paragraph = paragraphStyle(spacingBefore: spacingBefore, spacingAfter: spacingAfter, lineSpacing: 1.5)
        return [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ]
    }

    /// A paragraph style; the values are only valid while the style is created, so it is
    /// created inside their scope.
    private static func paragraphStyle(spacingBefore: CGFloat, spacingAfter: CGFloat, lineSpacing: CGFloat) -> CTParagraphStyle {
        var before = spacingBefore
        var after = spacingAfter
        var line = lineSpacing
        let size = MemoryLayout<CGFloat>.size
        return withUnsafePointer(to: &before) { beforePointer in
            withUnsafePointer(to: &after) { afterPointer in
                withUnsafePointer(to: &line) { linePointer in
                    let settings = [
                        CTParagraphStyleSetting(spec: .paragraphSpacingBefore, valueSize: size, value: beforePointer),
                        CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: size, value: afterPointer),
                        CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: size, value: linePointer),
                    ]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }
    }
}
