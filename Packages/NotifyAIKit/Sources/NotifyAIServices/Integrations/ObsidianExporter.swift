//
//  ObsidianExporter.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore

/// Writes notes as Markdown files into a folder, for Obsidian (or any app that reads a folder
/// of Markdown files).
///
/// Each file starts with YAML front matter (title, date, duration, participants, tags and the
/// note's id). Exporting a note again overwrites its file, found by the id, even if the user
/// renamed the file; a new note gets "2026-10-20 Title.md", numbered if the name is taken.
struct ObsidianExporter {
    static let idKey = "notifyai-id"

    /// - Returns: The file that was written.
    @discardableResult
    func export(_ snapshot: MarkdownExporter.NoteSnapshot, options: MarkdownExporter.Options, to folder: URL) throws -> URL {
        let content = Self.frontMatter(for: snapshot) + MarkdownExporter().markdown(for: snapshot, options: options)
        let target = try Self.existingFile(for: snapshot.id, in: folder) ?? Self.newFile(for: snapshot, in: folder)
        try Data(content.utf8).write(to: target, options: .atomic)
        return target
    }

    static func frontMatter(for snapshot: MarkdownExporter.NoteSnapshot) -> String {
        var lines = ["---", "title: \(yamlString(snapshot.title))", "date: \(snapshot.createdAt.formatted(.iso8601))"]
        if snapshot.duration > 0 {
            lines.append("duration: \(Int(snapshot.duration.rounded()))")
        }
        if !snapshot.participants.isEmpty {
            lines.append("participants:")
            lines += snapshot.participants.map { "  - \(yamlString($0))" }
        }
        // A tag needs a letter; purely numeric tags are not tags in Obsidian.
        var seen = Set<String>()
        let tags = (["notifyai"] + snapshot.labels.map(tag) + snapshot.keywords.map(tag)).filter { $0.contains(where: \.isLetter) && seen.insert($0).inserted }
        lines.append("tags:")
        lines += tags.map { "  - \($0)" }
        lines += ["\(idKey): \(snapshot.id.uuidString)", "---", ""]
        return lines.joined(separator: "\n")
    }

    /// The file a note was exported to before, found by the id in its front matter.
    static func existingFile(for id: UUID, in folder: URL) throws -> URL? {
        let marker = "\(idKey): \(id.uuidString)"
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return files.first { file in
            guard file.pathExtension.lowercased() == "md", let handle = try? FileHandle(forReadingFrom: file) else { return false }
            defer { try? handle.close() }
            // The front matter is at the start; reading the first kilobytes is enough.
            let head = (try? handle.read(upToCount: 4_096)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return head.contains(marker)
        }
    }

    private static func newFile(for snapshot: MarkdownExporter.NoteSnapshot, in folder: URL) -> URL {
        let date = snapshot.createdAt.formatted(.iso8601.year().month().day())
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>#^[]")
        let title = snapshot.title.components(separatedBy: invalid).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        let base = "\(date) \(title.isEmpty ? String(localized: "Notiz", bundle: .module) : title)"
        var candidate = folder.appending(path: base + ".md", directoryHint: .notDirectory)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = folder.appending(path: "\(base) \(number).md", directoryHint: .notDirectory)
            number += 1
        }
        return candidate
    }

    /// A string as YAML scalar, quoted so colons, quotes and leading symbols are safe.
    private static func yamlString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Obsidian tags: no spaces, only letters, digits, `-`, `_` and `/`.
    private static func tag(_ keyword: String) -> String {
        keyword.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || "-_/".contains($0) }
    }
}
