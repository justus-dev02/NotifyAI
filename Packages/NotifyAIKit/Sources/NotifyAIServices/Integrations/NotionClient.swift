//
//  NotionClient.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore

/// Creates a note as a Notion page below a page of the user, through Notion's public API.
///
/// The user creates an internal integration in Notion, copies its secret into NotifyAI and
/// shares the parent page with the integration. Sections become headings, lists become
/// bulleted lists, tasks to-dos with their state. Notion accepts at most 100 blocks per
/// request and 2,000 characters per text, so long notes are sent in parts.
struct NotionClient {
    static let apiVersion = "2022-06-28"
    static let baseURL = URL(string: "https://api.notion.com/v1/")
    static let blocksPerRequest = 100
    static let charactersPerText = 2_000

    let token: String
    let transport: any HTTPTransport

    /// The page's ID from a link ("…/Meetings-0123456789abcdef0123456789abcdef?pvs=4") or the
    /// ID itself, with or without dashes.
    static func pageID(from text: String) -> String? {
        let hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: "?#")).first?
            .replacingOccurrences(of: "-", with: "")
            .lowercased() ?? ""
        let candidates = hex.matches(of: /[0-9a-f]{32}/).map { String($0.output) }
        guard let id = candidates.last else { return nil }
        let characters = Array(id)
        return [characters[0..<8], characters[8..<12], characters[12..<16], characters[16..<20], characters[20..<32]]
            .map { String($0) }
            .joined(separator: "-")
    }

    /// Creates the page and returns its ID and address.
    func createPage(_ document: ExportDocument, parentPageID: String) async throws -> (id: String, url: URL?) {
        let blocks = Self.blocks(for: document)
        let first = Array(blocks.prefix(Self.blocksPerRequest))
        let body: [String: Any] = [
            "parent": ["page_id": parentPageID],
            "properties": ["title": ["title": Self.richText(document.title)]],
            "children": first,
        ]
        let response = try await send("pages", method: "POST", body: body)
        guard let id = response["id"] as? String else { throw IntegrationError.invalidResponse }
        var remaining = blocks.dropFirst(first.count)
        while !remaining.isEmpty {
            let part = Array(remaining.prefix(Self.blocksPerRequest))
            _ = try await send("blocks/\(id)/children", method: "PATCH", body: ["children": part])
            remaining = remaining.dropFirst(part.count)
        }
        return (id, (response["url"] as? String).flatMap(URL.init(string:)))
    }

    /// Moves an earlier version of the note to Notion's trash.
    func archivePage(_ id: String) async throws {
        _ = try await send("pages/\(id)", method: "PATCH", body: ["archived": true])
    }

    // MARK: - Blocks

    static func blocks(for document: ExportDocument) -> [[String: Any]] {
        var blocks: [[String: Any]] = [block("paragraph", ["rich_text": richText(document.metadata.joined(separator: " · "), color: "gray")])]
        for item in document.blocks {
            switch item {
            case .heading(let title, let level):
                blocks.append(block(level == 1 ? "heading_2" : "heading_3", ["rich_text": richText(title)]))
            case .paragraph(let text):
                blocks += text.components(separatedBy: "\n\n").map { block("paragraph", ["rich_text": richText($0)]) }
            case .bullets(let items):
                blocks += items.map { block("bulleted_list_item", ["rich_text": richText($0)]) }
            case .chapters(let chapters):
                blocks += chapters.map { chapter in
                    let rest = "  \(chapter.range)\(chapter.overview.isEmpty ? "" : " – \(chapter.overview)")"
                    return block("numbered_list_item", ["rich_text": richText(chapter.title, bold: true) + richText(rest)])
                }
            case .tasks(let tasks):
                blocks += tasks.map { task in
                    let details = task.details.isEmpty ? [] : richText("  (\(task.details))", color: "gray")
                    return block("to_do", ["rich_text": richText(task.text) + details, "checked": task.isDone])
                }
            case .markedPassages(let passages):
                blocks += passages.map { passage in
                    let text = passage.text ?? String(localized: "Keine Sprache an dieser Stelle", bundle: .module)
                    return block("bulleted_list_item", ["rich_text": richText(passage.time + "  ", bold: true) + richText(text)])
                }
            case .transcript(let lines):
                blocks += lines.map { line in
                    let speaker = line.speaker.map { richText($0 + ": ", bold: true) } ?? []
                    return block("paragraph", ["rich_text": richText(line.time + "  ", color: "gray") + speaker + richText(line.text)])
                }
            }
        }
        return blocks
    }

    private static func block(_ type: String, _ content: [String: Any]) -> [String: Any] {
        ["object": "block", "type": type, type: content]
    }

    /// Rich text objects of at most `charactersPerText` characters each.
    static func richText(_ text: String, bold: Bool = false, color: String = "default") -> [[String: Any]] {
        var parts: [String] = []
        var rest = Substring(text)
        repeat {
            parts.append(String(rest.prefix(charactersPerText)))
            rest = rest.dropFirst(charactersPerText)
        } while !rest.isEmpty
        return parts.map { part in
            ["type": "text", "text": ["content": part], "annotations": ["bold": bold, "color": color]]
        }
    }

    // MARK: - Requests

    private func send(_ path: String, method: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = Self.baseURL.flatMap({ URL(string: path, relativeTo: $0) }) else { throw IntegrationError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Notion allows about three requests per second; a 429 says how long to wait.
        for attempt in 0..<3 {
            let (data, response) = try await transport.send(request)
            if response.statusCode == 429, attempt < 2 {
                let wait = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 1
                try await Task.sleep(for: .seconds(min(wait, 10)))
                continue
            }
            if let error = IntegrationError.from(status: response.statusCode) { throw error }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        throw IntegrationError.rateLimited
    }
}
