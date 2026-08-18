//
//  HightlightService.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//  Updated for 100% On-Device NLP Role Summaries & Mindmaps.
//

import Foundation
import NaturalLanguage

final class HighlightService {
    private let llm: LLMService

    init(llm: LLMService = LLMService()) {
        self.llm = llm
    }

    /// Generates a role-specific summary tailored to the chosen role.
    func roleSummary(role: String, transcript: String, segments: [TranscriptSegment]) async throws -> Summary {
        let roleKeywords: [String: [String]] = [
            "Sales": ["kunde", "vertrieb", "umsatz", "angebot", "vertrag", "preis", "abschluss", "lead", "budget", "client", "deal"],
            "Team": ["aufgabe", "sprint", "todo", "meeting", "entwicklung", "testing", "abgabe", "review", "team", "task", "work"],
            "Leadership": ["strategie", "ziel", "roadmap", "entscheidung", "budget", "priorität", "vision", "quartal", "growth", "strategy"]
        ]

        let keywords = roleKeywords[role] ?? [role.lowercased()]
        let roleFilteredSegments = segments.filter { seg in
            let lower = seg.text.lowercased()
            return keywords.contains(where: { lower.contains($0) })
        }

        let textToSummarize = roleFilteredSegments.isEmpty
            ? transcript
            : roleFilteredSegments.map(\.text).joined(separator: " ")

        var summary = await llm.summarize(transcript: textToSummarize)
        summary.markdown = "### 👔 Rollen-Fokus: \(role)\n\n" + summary.markdown
        summary.citations = roleFilteredSegments.prefix(8).map(\.id)
        return summary
    }

    /// Generates a real Mindmap tree from key topics in the transcript.
    func makeMindmap(transcript: String) async throws -> Mindmap {
        let cleanText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            return Mindmap(root: "Keine Inhalte", children: [])
        }

        // Extract main key themes using linguistic analysis
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = cleanText

        var sentences: [String] = []
        tokenizer.enumerateTokens(in: cleanText.startIndex..<cleanText.endIndex) { range, _ in
            let s = String(cleanText[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if s.count >= 8 {
                sentences.append(s)
            }
            return true
        }

        // Identify key noun themes
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = cleanText

        var frequentNouns: [String: Int] = [:]
        tagger.enumerateTags(in: cleanText.startIndex..<cleanText.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            if tag == .noun {
                let noun = String(cleanText[range]).capitalized
                if noun.count > 3 {
                    frequentNouns[noun, default: 0] += 1
                }
            }
            return true
        }

        let topThemes = frequentNouns.sorted { $0.value > $1.value }.prefix(4).map(\.key)
        let rootTitle = topThemes.first ?? "Gesprächsnotizen"

        var children: [MindmapNode] = []
        for theme in topThemes {
            let relatedSentences = sentences.filter { $0.lowercased().contains(theme.lowercased()) }
            let subNodes = relatedSentences.prefix(3).map { s in
                MindmapNode(label: s.prefix(45) + (s.count > 45 ? "…" : ""), children: nil)
            }
            children.append(MindmapNode(label: theme, children: subNodes.isEmpty ? nil : Array(subNodes)))
        }

        if children.isEmpty {
            children = sentences.prefix(3).map { s in
                MindmapNode(label: s.prefix(40) + "…", children: nil)
            }
        }

        return Mindmap(root: rootTitle, children: children)
    }
}
