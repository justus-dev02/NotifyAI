//
//  Redactor.swift
//  NotifyAI
//

import Foundation

/// Replaces personal contact and banking data before text leaves the app.
enum Redactor {
    private struct Rule: Sendable {
        let expression: NSRegularExpression
        let replacement: String

        /// The patterns are compile-time constants and covered by `RedactorTests`,
        /// so a failure here is a programming error.
        init(_ pattern: String, replacement: String) {
            do {
                expression = try NSRegularExpression(pattern: pattern)
            } catch {
                preconditionFailure("Invalid redaction pattern \(pattern): \(error)")
            }
            self.replacement = replacement
        }
    }

    private static let rules: [Rule] = [
        // E-mail addresses.
        Rule(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, replacement: "[E-Mail]"),
        // IBANs, optionally written in groups of four: DE89 3704 0044 0532 0130 00.
        Rule(#"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,3})?\b"#, replacement: "[IBAN]"),
        // Phone numbers must start with + or 0 and contain 7–15 digits, so times, dates
        // and amounts ("14:30", "2026", "1.500") stay untouched.
        Rule(#"(?<![\w+])(?:\+|0)\d(?:[ \-/]?\d){6,14}\b"#, replacement: "[Telefonnummer]"),
    ]

    static func redact(_ text: String) -> String {
        rules.reduce(text) { result, rule in
            let range = NSRange(result.startIndex..., in: result)
            return rule.expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: rule.replacement)
            )
        }
    }
}
