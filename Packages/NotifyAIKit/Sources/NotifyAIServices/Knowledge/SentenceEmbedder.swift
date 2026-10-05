//
//  SentenceEmbedder.swift
//  NotifyAIServices
//

import Accelerate
import Foundation
import NaturalLanguage
import Synchronization

/// A unit-length vector that describes the meaning of a text.
///
/// Stored as raw half-precision (Float16) bytes: a 512-dimensional vector takes 1 KB instead
/// of 2 KB as Float32 or ~10 KB as a JSON number array. Half precision (about three
/// significant digits) changes cosine similarities by less than 0.001, far below the
/// differences that decide a ranking. In memory the values stay Float32 for vDSP.
/// The conversion uses vImage, which also works on Intel Macs (Swift's `Float16` does not).
struct EmbeddingVector: Codable, Hashable, Sendable {
    let values: [Float]

    init(_ values: [Float]) {
        self.values = values
    }

    /// Cosine similarity; both vectors are normalized, so this is the dot product.
    func similarity(to other: Self) -> Float {
        guard values.count == other.values.count, !values.isEmpty else { return 0 }
        return vDSP.dot(values, other.values)
    }

    /// The normalized mean of several vectors, e.g. all passages of a note.
    static func mean(of vectors: [Self]) -> Self? {
        guard let first = vectors.first else { return nil }
        var sum = [Float](repeating: 0, count: first.values.count)
        for vector in vectors where vector.values.count == sum.count {
            sum = vDSP.add(sum, vector.values)
        }
        return normalized(sum).map(Self.init)
    }

    static func normalized(_ values: [Float]) -> [Float]? {
        let length = vDSP.sumOfSquares(values).squareRoot()
        guard length > 0, length.isFinite else { return nil }
        return vDSP.divide(values, length)
    }

    init(from decoder: any Decoder) throws {
        let data = try decoder.singleValueContainer().decode(Data.self)
        guard let values = Self.decodeHalfPrecision(data) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid Float16 vector"))
        }
        self.values = values
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Self.encodeHalfPrecision(values))
    }

    /// Float32 → Float16 bytes.
    static func encodeHalfPrecision(_ values: [Float]) -> Data {
        var output = Data(count: values.count * MemoryLayout<UInt16>.size)
        guard !values.isEmpty else { return output }
        values.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBytes { destination in
                var sourceBuffer = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: source.baseAddress),
                    height: 1,
                    width: vImagePixelCount(values.count),
                    rowBytes: values.count * MemoryLayout<Float>.size
                )
                var destinationBuffer = vImage_Buffer(
                    data: destination.baseAddress,
                    height: 1,
                    width: vImagePixelCount(values.count),
                    rowBytes: values.count * MemoryLayout<UInt16>.size
                )
                vImageConvert_PlanarFtoPlanar16F(&sourceBuffer, &destinationBuffer, vImage_Flags(kvImageNoFlags))
            }
        }
        return output
    }

    /// Float16 bytes → Float32; `nil` if the data is not a whole number of Float16 values.
    static func decodeHalfPrecision(_ data: Data) -> [Float]? {
        guard data.count % MemoryLayout<UInt16>.size == 0 else { return nil }
        let count = data.count / MemoryLayout<UInt16>.size
        var values = [Float](repeating: 0, count: count)
        guard count > 0 else { return values }
        data.withUnsafeBytes { source in
            values.withUnsafeMutableBufferPointer { destination in
                var sourceBuffer = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: source.baseAddress),
                    height: 1,
                    width: vImagePixelCount(count),
                    rowBytes: count * MemoryLayout<UInt16>.size
                )
                var destinationBuffer = vImage_Buffer(
                    data: destination.baseAddress,
                    height: 1,
                    width: vImagePixelCount(count),
                    rowBytes: count * MemoryLayout<Float>.size
                )
                vImageConvert_Planar16FtoPlanarF(&sourceBuffer, &destinationBuffer, vImage_Flags(kvImageNoFlags))
            }
        }
        return values
    }
}

/// Turns text into meaning vectors for semantic search, related notes and summary sources.
/// Implemented by `SentenceEmbedder`; tests can pass a deterministic one.
protocol SentenceEmbedding: Sendable {
    /// The normalized vector of `text`, or `nil` if the language has no embedding.
    func vector(for text: String, languageCode: String) -> EmbeddingVector?
}

extension SentenceEmbedding {
    func supports(languageCode: String) -> Bool {
        vector(for: "Test", languageCode: languageCode) != nil
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
final class SentenceEmbedder: SentenceEmbedding {
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
}
