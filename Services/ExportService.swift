//
//  ExportService.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import PDFKit
import WebKit

final class ExportService {
    private let redact = RedactionService()

    func pdf(fromMarkdown md: String, redacted: Bool) async -> URL? {
        let html = markdownToHTML(redacted ? redact.redactPII(md) : md)
        return await renderHTMLToPDF(html: html)
    }

    private func markdownToHTML(_ md: String) -> String {
        """
        <html><head><meta name='viewport' content='width=device-width, initial-scale=1'>
        <style> body{font: -apple-system-body; padding:20px} h1,h2{margin-top:1em} code{font-family: ui-monospace}</style>
        </head><body>\(md.replacingOccurrences(of:"\n", with:"<br/>"))</body></html>
        """
    }

    private func renderHTMLToPDF(html: String) async -> URL? {
        await withCheckedContinuation { cont in
            let fmt = UIMarkupTextPrintFormatter(markupText: html)
            let r = UIPrintPageRenderer()
            r.addPrintFormatter(fmt, startingAtPageAt: 0)
            let a4 = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
            r.setValue(NSValue(cgRect: a4), forKey: "paperRect")
            r.setValue(NSValue(cgRect: a4.insetBy(dx: 24, dy: 24)), forKey: "printableRect")
            let data = NSMutableData()
            UIGraphicsBeginPDFContextToData(data, .zero, nil)
            for i in 0..<r.numberOfPages {
                UIGraphicsBeginPDFPage()
                r.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
            }
            UIGraphicsEndPDFContext()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("note_\(UUID().uuidString).pdf")
            do { try data.write(to: url); cont.resume(returning: url) } catch { cont.resume(returning: nil) }
        }
    }
}
