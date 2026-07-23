//
//  LLMService.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import Foundation

final class LLMService {
    enum Provider { case mlc }
    var provider: Provider = .mlc
    var modelId: String = "phi-3-mini-instruct-q4"

    func summarize(transcript: String) async -> Summary {
        do {
            let prompt = """
            System: Du bist ein Assistent für Meeting-Notizen. Antworte auf Deutsch.
            Aufgabe: Extrahiere
            - "highlights": Liste mit max. 7 Stichpunkten,
            - "decisions": Liste,
            - "actionItems": Liste aus Objekten { "owner": string|null, "task": string, "due": string|null (ISO8601) },
            - "risks": Liste,
            und gib außerdem eine saubere, formattierte Markdown-Zusammenfassung zurück.
            Formatiere die Ausgabe so:
            <JSON>
            { "highlights":[...], "decisions":[...], "actionItems":[...], "risks":[...] }
            </JSON>
            <MARKDOWN>
            (Markdown-Text)
            </MARKDOWN>

            TRANSCRIPT:
            \(transcript)
            """

            let raw = try await MLCBridge.shared.generate(modelId: modelId, prompt: prompt, maxTokens: 512)
            let (json, md) = try Self.extractJSONAndMarkdown(from: raw)
            var summary = try JSONDecoder().decode(Summary.self, from: json.data(using: .utf8)!)
            summary.markdown = md
            return summary
        } catch {
            return generateStructuredSummary(transcript: transcript)
        }
    }

    func generateStructuredSummary(transcript: String) -> Summary {
        let cleanText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanText.isEmpty {
            return Summary(
                highlights: ["Keine Sprachinhalte erfasst"],
                decisions: [],
                actionItems: [],
                risks: [],
                markdown: "### 📝 Zusammenfassung\n*Keine Sprachinhalte erfasst.*",
                citations: []
            )
        }
        
        let sentences = cleanText.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 3 }
        
        let highlightsList: [String] = sentences.prefix(5).map { sentence in
            sentence.hasSuffix(".") ? sentence : sentence + "."
        }
        
        var actionItems: [ActionItem] = []
        for sentence in sentences {
            let lower = sentence.lowercased()
            if lower.contains("müssen") || lower.contains("sollen") || lower.contains("aufgabe") || lower.contains("todo") || lower.contains("überprüfen") || lower.contains("erstellen") {
                actionItems.append(ActionItem(owner: "Team", task: sentence, due: nil))
            }
        }
        if actionItems.isEmpty {
            actionItems.append(ActionItem(owner: "Ich", task: "Protokoll & Ergebnisse überprüfen", due: nil))
        }
        
        var markdownBuilder = "### 📝 Executive Summary\n"
        markdownBuilder += "Das Gespräch wurde analysiert und die wesentlichen Kernpunkte zusammengefasst:\n\n"
        
        markdownBuilder += "#### 💡 Wichtigste Erkenntnisse\n"
        for highlight in (highlightsList.isEmpty ? ["Erfolgreiche Sprachaufzeichnung"] : highlightsList) {
            markdownBuilder += "- \(highlight)\n"
        }
        
        markdownBuilder += "\n#### 📌 Aufgaben & Action Items\n"
        for item in actionItems {
            markdownBuilder += "- [ ] **\(item.owner ?? "Team")**: \(item.task)\n"
        }
        
        return Summary(
            highlights: highlightsList.isEmpty ? ["Aufnahme verarbeitet"] : highlightsList,
            decisions: ["Gesprächsinhalte wurden verarbeitet"],
            actionItems: actionItems,
            risks: [],
            markdown: markdownBuilder,
            citations: []
        )
    }

    static func extractJSONAndMarkdown(from s: String) throws -> (String, String) {
        func between(_ text: String, _ open: String, _ close: String) -> String? {
            guard let r1 = text.range(of: open),
                  let r2 = text.range(of: close, range: r1.upperBound..<text.endIndex) else { return nil }
            return String(text[r1.upperBound..<r2.lowerBound])
        }
        guard let json = between(s, "<JSON>", "</JSON>"),
              let md   = between(s, "<MARKDOWN>", "</MARKDOWN>") else {
            throw NSError(domain: "LLM", code: -2, userInfo: [NSLocalizedDescriptionKey: "Output parse error"])
        }
        return (json.trimmingCharacters(in: .whitespacesAndNewlines),
                md.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

extension LLMService {
    func generateRaw(prompt: String, maxTokens: Int) async throws -> String {
        try await MLCBridge.shared.generate(modelId: modelId, prompt: prompt, maxTokens: maxTokens)
    }

    static func extractJSON(from s: String) throws -> String {
        if let r = s.range(of: "{"), let e = s.range(of: "}", options: .backwards) {
            return String(s[r.lowerBound...e.upperBound])
        }
        throw NSError(domain: "LLM", code: -3, userInfo: [NSLocalizedDescriptionKey: "JSON not found"])
    }
}
