//
//  TaskIdentity.swift
//  NotifyAICore
//

import Foundation

/// Recognizes the same task in two wordings, e.g. in a summary made again.
///
/// A summary made again phrases its tasks anew and gives them new identifiers. Without this,
/// ticked-off tasks would reappear as open and a task the user rewrote would appear twice.
/// Two texts describe the same task when most words of the shorter one occur in the longer
/// one; words are compared by their first five letters, so "Kunde" matches "Kunden" and
/// "schicken" matches "schickt".
public enum TaskIdentity {
    /// Share of the shorter text's words that must occur in the other one.
    static let minimumOverlap = 0.75

    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let left = stems(of: lhs)
        let right = stems(of: rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        let shared = left.intersection(right).count
        let shorter = min(left.count, right.count)
        // A single shared word is only enough when one text consists of that word alone.
        guard shared >= min(2, shorter) else { return false }
        return Double(shared) / Double(shorter) >= minimumOverlap
    }

    /// The words that carry the meaning: three letters or more, lowercased, cut to five letters.
    static func stems(of text: String) -> Set<String> {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !fillers.contains($0) }
        return Set(words.map { String($0.prefix(5)) })
    }

    /// Words that appear in almost every task and say nothing about which one it is.
    private static let fillers: Set<String> = [
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "und", "oder", "für",
        "mit", "von", "bis", "zum", "zur", "auf", "aus", "bei", "the", "and", "for", "with", "from", "until", "into",
    ]
}
