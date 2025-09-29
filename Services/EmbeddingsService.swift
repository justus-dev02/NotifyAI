//
//  EmbeddingsService.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import Foundation
import NaturalLanguage

struct Vector {
    var values: [Float]
}

final class EmbeddingsService {
    static let shared = EmbeddingsService()

    private let embedding: NLEmbedding? =
        NLEmbedding.wordEmbedding(for: .german) ?? NLEmbedding.wordEmbedding(for: .english)

    func embed(text: String) -> Vector? {
        guard let embedding else { return nil }
        let tokens = tokenize(text: text.lowercased())
        var sum = [Float](repeating: 0, count: embedding.dimension)
        var count: Float = 0

        for tok in tokens {
            guard let vector = embedding.vector(for: tok) else { continue }
            // `vector(for:)` returns [Double]; convert to Float for accumulation.
            let floatVector = vector.map { Float($0) }
            for index in 0..<min(sum.count, floatVector.count) {
                sum[index] += floatVector[index]
            }
            count += 1
        }
        guard count > 0 else { return nil }
        var mean = sum.map { $0 / count }
        // Normalisieren
        let norm = sqrt(mean.reduce(0) { $0 + $1*$1 })
        if norm > 0 {
            mean = mean.map { $0 / norm }
        }
        return Vector(values: mean)
    }

    func cosine(_ a: Vector, _ b: Vector) -> Float {
        let dot = zip(a.values, b.values).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        let na = sqrt(a.values.reduce(0) { $0 + $1*$1 })
        let nb = sqrt(b.values.reduce(0) { $0 + $1*$1 })
        guard na > 0 && nb > 0 else { return 0 }
        return dot / (na * nb)
    }

    private func tokenize(text: String) -> [String] {
        // leichte Tokenisierung (Whitespace + Satzzeichen trennen)
        return text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}
