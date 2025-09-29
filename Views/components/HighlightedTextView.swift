//
//  HighlightedTextView.swift
//  NotifyAI
//
//  Created by Justus on 29.09.25.
//

import SwiftUI

struct HighlightedTextView: View {
    let text: String
    let queryTerms: [String]

    var body: some View {
        let parts = split(text: text, by: queryTerms)
        Text(parts.map(\.rendered).joined())
            .textSelection(.enabled)
    }

    private func split(text: String, by terms: [String]) -> [(rendered: String, highlight: Bool)] {
        guard !terms.isEmpty else { return [(text, false)] }
        let pattern = terms.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        var res: [(String, Bool)] = []
        var idx = text.startIndex
        for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let r = Range(m.range, in: text)!
            if idx < r.lowerBound { res.append((String(text[idx..<r.lowerBound]), false)) }
            res.append(("\(text[r])", true))
            idx = r.upperBound
        }
        if idx < text.endIndex { res.append((String(text[idx..<text.endIndex]), false)) }
        return res
    }
}
