//
//  SentenceEmbedder.swift
//  NotifyAI
//

import Accelerate
import Foundation
import NaturalLanguage
import Synchronization

/// A unit-length vector that describes the meaning of a text.
///
/// Stored as raw Float32 bytes: a 512-dimensional vector takes 2 KB instead of the ~10 KB a
/// JSON number array would need.
struct EmbeddingVector: Codable, Hashable, Sendable {
    let values: [Float]

    init(_ values: [Float]) {
        self.values = values
    }

    /// Cosine similarity; both vectors are normalized, so this is the dot product.
    func similarity(to other: EmbeddingVector) -> Float {
        guard values.count == other.values.count, !values.isEmpty else { return 0 }
        return vDSP.dot(values, other.values)
    }

    /// The normalized mean of several vectors, e.g. all passages of a note.
    static func mean(of vectors: [EmbeddingVector]) -> EmbeddingVector? {
        guard let first = vectors.first else { return nil }
        var sum = [Float](repeating: 0, count: first.values.count)
        for vector in vectors where vector.values.count == sum.count {
            sum = vDSP.add(sum, vector.values)
        }
        return normalized(sum).map(EmbeddingVector.init)
    }

    static func normalized(_ values: [Float]) -> [Float]? {
        let length = vDSP.sumOfSquares(values).squareRoot()
        guard length > 0, length.isFinite else { return nil }
        return vDSP.divide(values, length)
    }

    init(from decoder: any Decoder) throws {
        let data = try decoder.singleValueContainer().decode(Data.self)
        values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values.withUnsafeBufferPointer { Data(buffer: $0) })
    }
}

/// Turns sentences and short paragraphs into meaning vectors with Apple's built-in sentence
/// embeddings (`NLEmbedding.sentenceEmbedding`).
///
/// Apple recommends these embeddings for semantic similarity. They are part of the OS (no
/// download, no app size), run on the CPU in about a millisecond per passage and exist for
/// German, English, French, Spanish, Italian, Portuguese and Chinese. Vectors of different
/// languages live in different spaces and are never compared with each other. For languages
/// without an embedding, search falls back to full-text matching.
final class SentenceEmbedder: Sendable {
    /// Loaded embeddings per language code; `nil` marks an unsupported language.
    private let embeddings = Mutex<[String: NLEmbedding?]>([:])

    init() {}

    func vector(for text: String, languageCode: String) -> EmbeddingVector? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return embeddings.withLock { cache in
            let embedding: NLEmbedding?
            if let cached = cache[languageCode] {
                embedding = cached
            } else {
                embedding = NLEmbedding.sentenceEmbedding(for: NLLanguage(rawValue: languageCode))
                cache[languageCode] = embedding
            }
            guard let embedding, let values = embedding.vector(for: trimmed) else { return nil }
            return EmbeddingVector.normalized(values.map(Float.init)).map(EmbeddingVector.init)
        }
    }

    func supports(languageCode: String) -> Bool {
        vector(for: "Test", languageCode: languageCode) != nil
    }
}
