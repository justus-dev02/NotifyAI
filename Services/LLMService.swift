//
//  LLMService.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//  Updated for 100% On-Device NLP & LLM Summarization.
//

import Foundation
import NaturalLanguage

final class LLMService {
    enum Provider {
        case onDeviceNLP
        case localModel
    }

    var provider: Provider = .onDeviceNLP
    var modelId: String = "on-device-nlp"

    /// Summarizes the given transcript into structured highlights, decisions, action items, risks, and markdown.
    func summarize(transcript: String) async -> Summary {
        let cleanText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            return Summary(
                highlights: ["Keine Sprachinhalte erfasst"],
                decisions: [],
                actionItems: [],
                risks: [],
                markdown: "### 📝 Zusammenfassung\n*Keine Sprachinhalte erfasst.*",
                citations: []
            )
        }

        return generateNLPSummary(from: cleanText)
    }

    // MARK: - On-Device NLP Summarizer Engine

    private func generateNLPSummary(from text: String) -> Summary {
        let sentences = extractSentences(from: text)
        guard !sentences.isEmpty else {
            return Summary(
                highlights: [text],
                decisions: [],
                actionItems: [],
                risks: [],
                markdown: "### 📝 Zusammenfassung\n\(text)",
                citations: []
            )
        }

        // 1. Calculate sentence importance scores using TF-IDF and length heuristics
        let rankedSentences = rankSentences(sentences, fullText: text)
        let topHighlights = Array(rankedSentences.prefix(min(6, max(2, sentences.count / 3))))

        // 2. Extract Decisions
        let decisions = extractDecisions(from: sentences)

        // 3. Extract Action Items with Assignees
        let actionItems = extractActionItems(from: sentences)

        // 4. Extract Risks / Open Issues
        let risks = extractRisks(from: sentences)

        // 5. Generate Markdown Report
        let markdown = buildMarkdown(
            highlights: topHighlights,
            decisions: decisions,
            actionItems: actionItems,
            risks: risks,
            fullText: text
        )

        return Summary(
            highlights: topHighlights,
            decisions: decisions,
            actionItems: actionItems,
            risks: risks,
            markdown: markdown,
            citations: []
        )
    }

    // MARK: - Linguistic Extraction Helpers

    private func extractSentences(from text: String) -> [String] {
        var sentences: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let raw = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.count >= 6 {
                sentences.append(raw)
            }
            return true
        }

        if sentences.isEmpty {
            sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 6 }
        }

        return sentences
    }

    private func rankSentences(_ sentences: [String], fullText: String) -> [String] {
        // Build term frequencies across the text
        var termFreq: [String: Int] = [:]
        let wordTokenizer = NLTokenizer(unit: .word)
        wordTokenizer.string = fullText
        wordTokenizer.enumerateTokens(in: fullText.startIndex..<fullText.endIndex) { range, _ in
            let word = String(fullText[range]).lowercased()
            if word.count > 3 && !isStopWord(word) {
                termFreq[word, default: 0] += 1
            }
            return true
        }

        // Score each sentence
        var scored: [(sentence: String, score: Double)] = []
        for (index, sentence) in sentences.enumerated() {
            var score: Double = 0
            wordTokenizer.string = sentence
            var wordCount = 0
            wordTokenizer.enumerateTokens(in: sentence.startIndex..<sentence.endIndex) { range, _ in
                let word = String(sentence[range]).lowercased()
                if let freq = termFreq[word] {
                    score += Double(freq)
                }
                wordCount += 1
                return true
            }

            if wordCount > 0 {
                score = score / Double(wordCount)
            }

            // Position bias: early and concluding sentences often hold summary value
            if index == 0 || index == sentences.count - 1 {
                score *= 1.3
            }

            scored.append((sentence, score))
        }

        // Sort by score descending and return
        let sorted = scored.sorted { $0.score > $1.score }.map { $0.sentence }
        return sorted
    }

    private func extractDecisions(from sentences: [String]) -> [String] {
        let decisionKeywords = [
            "beschlossen", "entschieden", "vereinbart", "festgelegt", "einig",
            "ergebnis ist", "konsens", "abgemacht", "beschluss", "decided",
            "agreed", "concluded", "approved", "finalized"
        ]

        var decisions: [String] = []
        for s in sentences {
            let lower = s.lowercased()
            if decisionKeywords.contains(where: { lower.contains($0) }) {
                decisions.append(s)
            }
        }
        return decisions
    }

    private func extractActionItems(from sentences: [String]) -> [ActionItem] {
        let actionKeywords = [
            "müssen", "sollen", "aufgabe", "todo", "erledigen", "erstellen",
            "überprüfen", "schicken", "senden", "vorbereiten", "kontaktieren",
            "anrufen", "fertigstellen", "implementieren", "must", "should", "will"
        ]

        var items: [ActionItem] = []
        for s in sentences {
            let lower = s.lowercased()
            if actionKeywords.contains(where: { lower.contains($0) }) {
                // Determine potential owner from sentence
                var owner = "Team"
                if lower.contains("ich ") || lower.contains("ich werde") {
                    owner = "Ich"
                } else if lower.contains("wir ") {
                    owner = "Team"
                } else {
                    // Try named entity recognition
                    let tagger = NLTagger(tagSchemes: [.nameType])
                    tagger.string = s
                    tagger.enumerateTags(in: s.startIndex..<s.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
                        if tag == .personalName {
                            owner = String(s[range])
                            return false
                        }
                        return true
                    }
                }

                items.append(ActionItem(
                    owner: owner,
                    task: s,
                    due: nil,
                    status: .open
                ))
            }
        }

        return items
    }

    private func extractRisks(from sentences: [String]) -> [String] {
        let riskKeywords = [
            "risiko", "gefahr", "problem", "schwierig", "unklar", "bedenken",
            "herausforderung", "kritisch", "risk", "issue", "problem", "concern"
        ]

        var risks: [String] = []
        for s in sentences {
            let lower = s.lowercased()
            if riskKeywords.contains(where: { lower.contains($0) }) {
                risks.append(s)
            }
        }
        return risks
    }

    private func isStopWord(_ word: String) -> Bool {
        let stopWords: Set<String> = [
            "der", "die", "das", "und", "ist", "in", "den", "von", "zu", "mit",
            "für", "auf", "ein", "eine", "einer", "einem", "einen", "nicht", "auch",
            "es", "an", "als", "nach", "wie", "im", "um", "dem", "the", "and", "is",
            "in", "to", "of", "for", "with", "on", "at", "by", "this", "that"
        ]
        return stopWords.contains(word)
    }

    private func buildMarkdown(
        highlights: [String],
        decisions: [String],
        actionItems: [ActionItem],
        risks: [String],
        fullText: String
    ) -> String {
        var md = "### 📝 Executive Summary\n"
        if !highlights.isEmpty {
            md += highlights.prefix(3).joined(separator: " ") + "\n\n"
        } else {
            md += "Die Aufnahme wurde erfolgreich lokal analysiert.\n\n"
        }

        if !highlights.isEmpty {
            md += "#### 💡 Wichtigste Erkenntnisse\n"
            for h in highlights {
                md += "- \(h)\n"
            }
            md += "\n"
        }

        if !decisions.isEmpty {
            md += "#### ✅ Getroffene Entscheidungen\n"
            for d in decisions {
                md += "- \(d)\n"
            }
            md += "\n"
        }

        if !actionItems.isEmpty {
            md += "#### 📌 Aufgaben & Action Items\n"
            for item in actionItems {
                let ownerStr = item.owner ?? "Team"
                md += "- [ ] **\(ownerStr)**: \(item.task)\n"
            }
            md += "\n"
        }

        if !risks.isEmpty {
            md += "#### ⚠️ Risiken & Offene Punkte\n"
            for r in risks {
                md += "- \(r)\n"
            }
            md += "\n"
        }

        return md.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension LLMService {
    func generateRaw(prompt: String, maxTokens: Int) async throws -> String {
        let summary = await summarize(transcript: prompt)
        return summary.markdown
    }
}
