//
//  HightlightService.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import Foundation

final class HighlightService {
    func roleSummary(role: String, transcript: String, segments: [TranscriptSegment]) async throws -> Summary {
        let prompt = """
        System: Du erstellst rollenspezifische Zusammenfassungen. Rolle: \(role).
        Aufgabe: Extrahiere Highlights, Decisions, ActionItems (mit Owner/Due), Risks.
        Antworte im gleichen Format wie die Standardsummary.
        Kontext: \(transcript.prefix(12000))
        """
        let raw = try await ServiceLocator.shared.llm.generateRaw(prompt: prompt, maxTokens: 512)
        let (json, md) = try LLMService.extractJSONAndMarkdown(from: raw)
        var s = try JSONDecoder().decode(Summary.self, from: json.data(using: .utf8)!)
        s.markdown = md
        // einfache Citations-Heuristik:
        s.citations = segments.prefix(8).map(\.id)
        return s
    }

    func makeMindmap(transcript: String) async throws -> Mindmap {
        let prompt = """
        Erzeuge eine kompakte Mindmap-Struktur als JSON:
        { "root":"Titel", "children":[ { "label":"Thema", "children":[...]} ] }
        Fokus: Themenblöcke, Entscheidungen, offene Punkte.
        Text: \(transcript.prefix(12000))
        """
        let raw = try await ServiceLocator.shared.llm.generateRaw(prompt: prompt, maxTokens: 600)
        let json = try LLMService.extractJSON(from: raw)
        return try JSONDecoder().decode(Mindmap.self, from: json.data(using: .utf8)!)
    }
}
