//
//  ExportService.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//  Updated for Full PDF, Markdown, and Mermaid Graph Exports.
//

import PDFKit
import WebKit
import UIKit

final class ExportService {
    private let redact = RedactionService()

    /// Generates a PDF file from Markdown content with custom styling
    func pdf(fromMarkdown md: String, redacted: Bool) async -> URL? {
        let content = redacted ? redact.redactPII(md) : md
        let html = markdownToHTML(content)
        return await renderHTMLToPDF(html: html)
    }

    /// Exports raw markdown text to a temporary .md file for sharing
    func exportMarkdownFile(content: String, title: String) -> URL? {
        let filename = "\(sanitizeFilename(title)).md"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            print("ExportService markdown export error: \(error)")
            return nil
        }
    }

    /// Exports Mermaid mindmap diagram to a .mmd file
    func exportMermaidFile(mindmap: Mindmap, title: String) -> URL? {
        let mermaidCode = generateMermaidCode(from: mindmap)
        let filename = "\(sanitizeFilename(title))_mindmap.mmd"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try mermaidCode.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            print("ExportService mermaid export error: \(error)")
            return nil
        }
    }

    /// Converts a Mindmap tree to valid Mermaid diagram syntax
    func generateMermaidCode(from mindmap: Mindmap) -> String {
        var code = "mindmap\n  root((\"\(mindmap.root)\"))\n"
        for child in mindmap.children {
            code += "    [\"\(child.label)\"]\n"
            if let subChildren = child.children {
                for sub in subChildren {
                    code += "      (\"\(sub.label)\")\n"
                }
            }
        }
        return code
    }

    private func markdownToHTML(_ md: String) -> String {
        let htmlBody = md
            .replacingOccurrences(of: "\n", with: "<br/>")
            .replacingOccurrences(of: "### ", with: "<h3>")
            .replacingOccurrences(of: "#### ", with: "<h4>")

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name='viewport' content='width=device-width, initial-scale=1'>
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                    padding: 36px;
                    color: #1A1A1A;
                    line-height: 1.6;
                }
                h1, h2, h3, h4 { color: #3A36DB; margin-top: 1.2em; margin-bottom: 0.4em; }
                h3 { font-size: 1.3em; border-bottom: 1px solid #E5E7EB; padding-bottom: 4px; }
                h4 { font-size: 1.1em; color: #4F46E5; }
                p, li { font-size: 14px; color: #374151; }
                .footer { margin-top: 40px; font-size: 11px; color: #9CA3AF; text-align: center; border-top: 1px solid #E5E7EB; padding-top: 10px; }
            </style>
        </head>
        <body>
            \(htmlBody)
            <div class='footer'>Erstellt mit NotifyAI • 100% On-Device & Vertraulich</div>
        </body>
        </html>
        """
    }

    @MainActor
    private func renderHTMLToPDF(html: String) async -> URL? {
        let fmt = UIMarkupTextPrintFormatter(markupText: html)
        let r = UIPrintPageRenderer()
        r.addPrintFormatter(fmt, startingAtPageAt: 0)

        // DIN A4 Page Size
        let a4 = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        r.setValue(NSValue(cgRect: a4), forKey: "paperRect")
        r.setValue(NSValue(cgRect: a4.insetBy(dx: 30, dy: 30)), forKey: "printableRect")

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, .zero, nil)
        for i in 0..<r.numberOfPages {
            UIGraphicsBeginPDFPage()
            r.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NotifyAI_\(UUID().uuidString.prefix(8)).pdf")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private func sanitizeFilename(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "\\/:*?\"<>| ")
        let clean = name.components(separatedBy: invalidChars).filter { !$0.isEmpty }.joined(separator: "_")
        return clean.isEmpty ? "Notiz" : clean
    }
}
