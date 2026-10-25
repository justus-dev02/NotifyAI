//
//  IndexedTerms.swift
//  NotifyAIKnowledge
//

import Foundation

/// The distinct search terms of a note, sorted. Each term is stored once per note instead of
/// once per passage: a dictionary of strings in every passage made up half of the index's
/// memory (see `PerformanceBenchmarks.testLoadingSearchIndexOf2000Notes`).
struct NoteTerms: Codable, Hashable, Sendable {
    private(set) var terms: [String] = []

    init(terms: some Sequence<String> = []) {
        self.terms = Set(terms).sorted()
    }

    /// The position of `term`, or `nil` if no passage of the note contains it.
    func id(of term: String) -> UInt32? {
        var low = 0
        var high = terms.count
        while low < high {
            let middle = (low + high) / 2
            if terms[middle] < term {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < terms.count && terms[low] == term ? UInt32(low) : nil
    }

    /// The frequencies of a passage's terms; every term must be one of the note's.
    func frequencies(of passageTerms: [String]) -> PassageTerms {
        let counts = passageTerms.reduce(into: [UInt32: Int]()) { counts, term in
            if let id = id(of: term) { counts[id, default: 0] += 1 }
        }
        let sorted = counts.sorted { $0.key < $1.key }
        return PassageTerms(ids: sorted.map(\.key), counts: sorted.map { UInt16(clamping: $0.value) })
    }

    /// Stored as one string with the terms separated by U+001F, which a term never contains:
    /// a property list decodes one string much faster than thousands.
    init(from decoder: any Decoder) throws {
        let joined = try decoder.singleValueContainer().decode(String.self)
        terms = joined.isEmpty ? [] : joined.split(separator: Self.separator, omittingEmptySubsequences: false).map(String.init)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(terms.joined(separator: String(Self.separator)))
    }

    private static let separator: Character = "\u{1F}"
}

/// How often each term of the note occurs in one passage: sorted term positions and counts.
struct PassageTerms: Codable, Hashable, Sendable {
    private(set) var ids: [UInt32] = []
    private(set) var counts: [UInt16] = []

    /// How often the term at `id` of the note's `terms` occurs, `nil` if not at all.
    func frequency(of id: UInt32) -> Int? {
        var low = 0
        var high = ids.count
        while low < high {
            let middle = (low + high) / 2
            if ids[middle] < id {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < ids.count && ids[low] == id ? Int(counts[low]) : nil
    }
}

// Stored as raw bytes, the ids followed by the counts: a property list decodes one data value
// much faster than an array of numbers. In an extension, so the memberwise initializer stays.
extension PassageTerms {
    init(from decoder: any Decoder) throws {
        let data = try decoder.singleValueContainer().decode(Data.self)
        let entrySize = MemoryLayout<UInt32>.size + MemoryLayout<UInt16>.size
        guard data.count % entrySize == 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid term frequencies"))
        }
        let count = data.count / entrySize
        let idBytes = count * MemoryLayout<UInt32>.size
        ids = [UInt32](repeating: 0, count: count)
        counts = [UInt16](repeating: 0, count: count)
        ids.withUnsafeMutableBytes { _ = data.prefix(idBytes).copyBytes(to: $0) }
        counts.withUnsafeMutableBytes { _ = data.dropFirst(idBytes).copyBytes(to: $0) }
    }

    func encode(to encoder: any Encoder) throws {
        var data = ids.withUnsafeBytes { Data($0) }
        counts.withUnsafeBytes { data.append(contentsOf: $0) }
        var container = encoder.singleValueContainer()
        try container.encode(data)
    }
}
