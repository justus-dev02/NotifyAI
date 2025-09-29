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
        let vector: Vector
        let title: String
        let preview: String
    }

    private var index: [IndexedNote] = []

    func buildIndex(notes: [Note]) {
        index.removeAll(keepingCapacity: true)
        for n in notes {
            let text = n.summary?.markdown ?? n.segments.map{$0.text}.joined(separator: " ")
            if let v = emb.embed(text: text) {
                let preview = String(text.prefix(240))
                index.append(.init(noteId: n.id, vector: v, title: n.title, preview: preview))
            }
        }
    }

    func search(_ query: String, topK: Int = 10) -> [UUID] {
        guard let qv = emb.embed(text: query) else { return [] }
        let scored = index.map { (id: $0.noteId, score: emb.cosine(qv, $0.vector)) }
        return scored.sorted { $0.score > $1.score }.prefix(topK).map { $0.id }
    }
}
