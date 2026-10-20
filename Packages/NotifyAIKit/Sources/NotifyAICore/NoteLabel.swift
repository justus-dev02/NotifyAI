//
//  NoteLabel.swift
//  NotifyAICore
//

import Foundation

/// Labels the user gives notes ("Samsung", "Projekt Atlas", "Statistik II").
///
/// A label names the context of a note that its text often does not say: the company the
/// user works for, a project, a course. Labels are compared without case and accents, so
/// "samsung" and "Samsung" are the same label; the spelling the user chose first is kept.
public enum NoteLabel {
    /// Longer labels are cut; a label is a name, not a sentence.
    public static let maximumLength = 40

    /// The label as stored: without a leading "#", surrounding spaces and double spaces;
    /// `nil` when nothing is left.
    public static func normalized(_ text: String) -> String? {
        var label = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while label.hasPrefix("#") {
            label.removeFirst()
        }
        label = label.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        label = String(label.prefix(maximumLength)).trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : label
    }

    /// What identifies a label: lowercased, without accents.
    public static func key(_ label: String) -> String {
        label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// The keys of a note's labels in one string ("|samsung|projekt atlas|"), so a database
    /// query can find the notes with a label.
    public static func keyList(of labels: [String]) -> String {
        labels.isEmpty ? "" : "|" + labels.map(key).joined(separator: "|") + "|"
    }

    /// What `keyList` contains for one label, for queries.
    public static func queryToken(for label: String) -> String {
        "|" + key(label) + "|"
    }

    /// Normalized labels without duplicates, in the given order.
    public static func unique(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        return labels.compactMap(normalized).filter { seen.insert(key($0)).inserted }
    }
}
