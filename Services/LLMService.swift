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
    var modelId: String = "phi-3-mini-instruct-q4" // dein verpackter Modellname

    func summarize(transcript: String) async throws -> Summary {
        let prompt = """
        System: Du bist ein Assistent für Meeting-Notizen. Antworte auf Deutsch, wenn der Input Deutsch ist.
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
    }

    private static func extractJSONAndMarkdown(from s: String) throws -> (String, String) {
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
    
    extension LLMService {
        func generateRaw(prompt: String, maxTokens: Int) async throws -> String {
            try await MLCBridge.shared.generate(modelId: modelId, prompt: prompt, maxTokens: maxTokens)
        }
        static func extractJSON(from s: String) throws -> String {
            // Falls der Bot reinen JSON liefert:
            if let r = s.range(of: "{"), let e = s.range(of: "}", options: .backwards) {
                return String(s[r.lowerBound...e.upperBound])
            }
            throw NSError(domain: "LLM", code: -3, userInfo: [NSLocalizedDescriptionKey: "JSON not found"])
        }
    }
}

