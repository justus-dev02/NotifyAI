//
//  PassageVectors.swift
//  NotifyAIKnowledge
//

import Accelerate
import Foundation
import NotifyAISupport

/// The meaning vectors of a note's passages: one per window of about 25 words, several per
/// passage, so a question about one statement is not blurred by the rest of the passage.
///
/// The vectors are kept as 8-bit integers with one scale each: a quarter of the memory of
/// Float32, and on `SearchEvaluationCorpus.json` every ranking stayed the same. Scoring
/// converts one note's rows at a time and multiplies them with the question in one call.
struct PassageVectors: Hashable, Sendable {
    private(set) var dimension = 0
    /// The passage (position in `IndexedNote.passages`) of every row.
    private(set) var passages: [UInt32] = []
    private(set) var scales: [Float] = []
    /// Row after row, `dimension` values each.
    private(set) var values: [Int8] = []

    var count: Int { passages.count }

    init() {}

    /// - Parameter vectors: Unit vectors, each with its passage's position.
    init(_ vectors: [(passage: Int, vector: EmbeddingVector)]) {
        guard let first = vectors.first else { return }
        dimension = first.vector.values.count
        for (passage, vector) in vectors where vector.values.count == dimension {
            let largest = vector.values.lazy.map(abs).max() ?? 0
            let scale = largest > 0 ? largest / 127 : 1
            passages.append(UInt32(passage))
            scales.append(scale)
            values += vector.values.map { Int8(clamping: Int(($0 / scale).rounded())) }
        }
    }

    /// The best similarity of each passage to `query`, -1 for passages without a vector.
    /// - Parameter scratch: Reused between notes, so scoring allocates once per question.
    func bestScores(for query: [Float], passageCount: Int, scratch: inout [Float]) -> [Float] {
        var best = [Float](repeating: -1, count: passageCount)
        guard !passages.isEmpty, query.count == dimension else { return best }
        let total = count * dimension
        if scratch.count < total {
            scratch = [Float](repeating: 0, count: total)
        }
        var dots = [Float](repeating: 0, count: count)
        values.withUnsafeBufferPointer { values in
            scratch.withUnsafeMutableBufferPointer { matrix in
                query.withUnsafeBufferPointer { query in
                    dots.withUnsafeMutableBufferPointer { dots in
                        guard let values = values.baseAddress, let matrix = matrix.baseAddress,
                              let query = query.baseAddress, let dots = dots.baseAddress
                        else { return }
                        // The scratch buffer may be longer than this note's rows: convert exactly `total`.
                        vDSP_vflt8(values, 1, matrix, 1, vDSP_Length(total))
                        // rows × dimension times dimension × 1.
                        vDSP_mmul(matrix, 1, query, 1, dots, 1, vDSP_Length(count), 1, vDSP_Length(dimension))
                    }
                }
            }
        }
        for row in 0..<count {
            let passage = Int(passages[row])
            guard passage < passageCount else { continue }
            best[passage] = max(best[passage], dots[row] * scales[row])
        }
        return best
    }
}

// Stored as raw bytes: a property list decodes a few data values much faster than arrays of
// numbers. In an extension, so the memberwise initializer stays.
extension PassageVectors: Codable {
    private enum CodingKeys: String, CodingKey {
        case dimension, passages, scales, values
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dimension = try container.decode(Int.self, forKey: .dimension)
        passages = try Self.decodeArray(UInt32.self, from: container.decode(Data.self, forKey: .passages))
        scales = try Self.decodeArray(Float.self, from: container.decode(Data.self, forKey: .scales))
        values = try Self.decodeArray(Int8.self, from: container.decode(Data.self, forKey: .values))
        guard passages.count == scales.count, values.count == passages.count * dimension else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Inconsistent passage vectors"))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dimension, forKey: .dimension)
        try container.encode(passages.withUnsafeBytes { Data($0) }, forKey: .passages)
        try container.encode(scales.withUnsafeBytes { Data($0) }, forKey: .scales)
        try container.encode(values.withUnsafeBytes { Data($0) }, forKey: .values)
    }

    private static func decodeArray<T: BitwiseCopyable>(_ type: T.Type, from data: Data) throws -> [T] {
        guard data.count % MemoryLayout<T>.size == 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid passage vector data"))
        }
        return [T](unsafeUninitializedCapacity: data.count / MemoryLayout<T>.size) { buffer, count in
            count = data.copyBytes(to: buffer) / MemoryLayout<T>.size
        }
    }
}
