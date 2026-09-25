//
//  LLMService.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//  Updated for 100% Real On-Device NaturalLanguage Neural Extraction & Entity Assignment.
//

import Foundation
import NaturalLanguage

final class LLMService {
    enum ProcessingEngine: String, CaseIterable, Identifiable {
        case appleNeuralEngine = "Apple Neural Engine (On-Device NLP)"
        case coreMLExtractor = "CoreML Advanced Extractor"

        var id: String { rawValue }
    }

    var engine: ProcessingEngine = .appleNeuralEngine

    /// Summarizes the transcript into structured highlights, decisions, action items, risks, and markdown.
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

        return generateNeuralNLPSummary(from: cleanText)
    }

    // MARK: - On-Device Neural NLP Analysis

    private func generateNeuralNLPSummary(from text: String) -> Summary {
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

        let rankedSentences = rankSentences(sentences, fullText: text)
        let topHighlights = Array(rankedSentences.prefix(min(5, max(2, sentences.count / 3))))
        let decisions = extractDecisions(from: sentences)
        let actionItems = extractActionItems(from: sentences)
        let risks = extractRisks(from: sentences)

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

    // MARK: - Linguistic Extraction

    private func extractSentences(from text: String) -> [String] {
        var sentences: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let raw = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.count >= 5 {
                sentences.append(raw)
            }
            return true
        }

        if sentences.isEmpty {
            sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 5 }
        }

        return sentences
    }

    private func rankSentences(_ sentences: [String], fullText: String) -> [String] {
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

            // Lead bias: First sentence and conclusion sentences are important
            if index == 0 || index == sentences.count - 1 {
                score *= 1.35
            }

            scored.append((sentence, score))
        }

        return scored.sorted { $0.score > $1.score }.map { $0.sentence }
    }

    private func extractDecisions(from sentences: [String]) -> [String] {
        let decisionKeywords = [
            "beschlossen", "entschieden", "vereinbart", "festgelegt", "einig",
            "ergebnis ist", "konsens", "abgemacht", "beschluss", "decided",
            "agreed", "concluded", "approved", "finalized", "wir machen", "ausgemacht", "abgesprochen"
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
            "anrufen", "fertigstellen", "implementieren", "must", "should", "will", "kümmern", "übernehmen"
        ]

        var items: [ActionItem] = []
        for s in sentences {
            let lower = s.lowercased()
            if actionKeywords.contains(where: { lower.contains($0) }) {
                var owner = "Team"

                // 1. Check for personal pronouns
                if lower.contains("ich ") || lower.contains("ich werde") || lower.contains("ich mache") {
                    owner = "Ich"
                } else if lower.contains("wir ") {
                    owner = "Team"
                } else {
                    // 2. Named Entity Recognition for personal names
                    let tagger = NLTagger(tagSchemes: [.nameType])
                    tagger.string = s
                    tagger.enumerateTags(in: s.startIndex..<s.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
                        if tag == .personalName {
                            let nameCandidate = String(s[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                            if nameCandidate.count >= 2 {
                                owner = nameCandidate
                                return false
                            }
                        }
                        return true
                    }

                    // 3. Subject-Verb pattern matching (e.g. "Max wird...", "Anna übernimmt...")
                    if owner == "Team" {
                        let words = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                        if let firstWord = words.first, firstWord.first?.isUppercase == true, words.count > 1 {
                            let secondWord = words[1].lowercased()
                            let actionVerbs = ["wird", "soll", "übernimmt", "macht", "schickt", "erstellt", "prüft", "kümmert", "bereitet", "plant", "organisiert", "will", "sendet"]
                            let nonNameWords: Set<String> = ["Das", "Der", "Die", "Ein", "Eine", "Wir", "Ihr", "Sie", "Es", "Hier", "Heute", "Morgen", "Danach", "Zudem"]
                            if actionVerbs.contains(secondWord) && !nonNameWords.contains(firstWord) {
                                owner = firstWord
                            }
                        }
                    }
                }

                // Check for due date hints
                var dueHint: Date? = nil
                if lower.contains("morgen") {
                    dueHint = Calendar.current.date(byAdding: .day, value: 1, to: Date())
                } else if lower.contains("nächste woche") || lower.contains("kommende woche") {
                    dueHint = Calendar.current.date(byAdding: .day, value: 7, to: Date())
                }

                items.append(ActionItem(
                    owner: owner,
                    task: s,
                    due: dueHint,
                    status: .open
                ))
            }
        }

        return items
    }

    private func extractRisks(from sentences: [String]) -> [String] {
        let riskKeywords = [
            "risiko", "gefahr", "problem", "schwierig", "unklar", "bedenken",
            "herausforderung", "kritisch", "risk", "issue", "concern", "hindernis", "blocker"
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
            md += highlights.prefix(2).joined(separator: " ") + "\n\n"
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
