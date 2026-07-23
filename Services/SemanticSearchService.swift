//
//  SemanticSearchService.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import Foundation

final class SemanticSearchService {
    static let shared = SemanticSearchService()
    private let emb = EmbeddingsService.shared

    struct IndexedNote {
        let noteId: UUID
        let vector: Vector?
        let title: String
        let fullText: String
    }

    private var index: [IndexedNote] = []

    func buildIndex(notes: [Note]) {
        index.removeAll(keepingCapacity: true)
        for n in notes {
            let fullText = [
                n.title,
                n.summary?.markdown ?? "",
                n.segments.map { $0.text }.joined(separator: " "),
                n.tags.joined(separator: " "),
                n.highlights.joined(separator: " ")
            ].joined(separator: " ").lowercased()

            let v = emb.embed(text: fullText)
            index.append(.init(noteId: n.id, vector: v, title: n.title, fullText: fullText))
        }
    }

    func search(_ query: String, topK: Int = 20) -> [UUID] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return index.map { $0.noteId } }

        var results: [(id: UUID, score: Double)] = []
        let queryVector = emb.embed(text: q)

        for item in index {
            var score: Double = 0.0
            
            // Full-text keyword matching (Exact & Prefix)
            if item.fullText.contains(q) {
                score += 10.0
            }
            let terms = q.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            for term in terms {
                if item.title.lowercased().contains(term) {
                    score += 5.0
                } else if item.fullText.contains(term) {
                    score += 2.0
                }
            }

            // Semantic cosine similarity fallback/boost
            if let qv = queryVector, let iv = item.vector {
                let cosSim = Double(emb.cosine(qv, iv))
                if cosSim > 0.3 {
                    score += cosSim * 5.0
                }
            }

            if score > 0 {
                results.append((id: item.noteId, score: score))
            }
        }

        return results.sorted { $0.score > $1.score }.prefix(topK).map { $0.id }
    }
}
