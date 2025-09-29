//
//  ExportService.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import Foundation
import UIKit

final class ExportService {
    private let redact = RedactionService()

    func markdown(for note: Note, redacted: Bool) -> String {
        let md = note.summary?.markdown ?? note.segments.map{$0.text}.joined(separator: " ")
        return redacted ? redact.redactPII(md) : md
    }

    func exportMarkdown(_ md: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("note_\(UUID().uuidString).md")
        do { try md.data(using: .utf8)?.write(to: url) ; return url } catch { return nil }
    }
}
