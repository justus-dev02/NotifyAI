//
//  Summary.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import Foundation

struct Summary: Codable {
    var highlights: [String]
    var decisions: [String]
    var actionItems: [ActionItem]
    var risks: [String]
    var markdown: String
    var citations: [UUID]

    enum CodingKeys: String, CodingKey {
        case highlights, decisions, actionItems, risks, markdown, citations
    }

    init(highlights: [String] = [],
         decisions: [String] = [],
         actionItems: [ActionItem] = [],
         risks: [String] = [],
         markdown: String = "",
         citations: [UUID] = []) {
        self.highlights = highlights
        self.decisions = decisions
        self.actionItems = actionItems
        self.risks = risks
        self.markdown = markdown
        self.citations = citations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        highlights = try container.decodeIfPresent([String].self, forKey: .highlights) ?? []
        decisions = try container.decodeIfPresent([String].self, forKey: .decisions) ?? []
        actionItems = try container.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
        risks = try container.decodeIfPresent([String].self, forKey: .risks) ?? []
        markdown = try container.decodeIfPresent(String.self, forKey: .markdown) ?? ""
        citations = try container.decodeIfPresent([UUID].self, forKey: .citations) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(highlights, forKey: .highlights)
        try container.encode(decisions, forKey: .decisions)
        try container.encode(actionItems, forKey: .actionItems)
        try container.encode(risks, forKey: .risks)
        try container.encode(markdown, forKey: .markdown)
        try container.encode(citations, forKey: .citations)
    }
}

struct ActionItem: Identifiable, Codable {
    enum Status: String, CaseIterable, Codable {
        case open
        case inProgress
        case completed
        case blocked

        var displayName: String {
            switch self {
            case .open: return "Offen"
            case .inProgress: return "In Arbeit"
            case .completed: return "Erledigt"
            case .blocked: return "Blockiert"
            }
        }
    }

    let id: UUID
    var owner: String?
    var task: String
    var due: Date?
    var status: Status
    var sourceURL: URL?

    enum CodingKeys: String, CodingKey {
        case id, owner, task, due, status, sourceURL
    }

    init(id: UUID = UUID(),
         owner: String? = nil,
         task: String,
         due: Date? = nil,
         status: Status = .open,
         sourceURL: URL? = nil) {
        self.id = id
        self.owner = owner
        self.task = task
        self.due = due
        self.status = status
        self.sourceURL = sourceURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        task = try container.decode(String.self, forKey: .task)
        if let dateString = try container.decodeIfPresent(String.self, forKey: .due) {
            let formatter = ISO8601DateFormatter()
            due = formatter.date(from: dateString)
        } else {
            due = nil
        }
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .open
        if let urlString = try container.decodeIfPresent(String.self, forKey: .sourceURL),
           let url = URL(string: urlString) {
            sourceURL = url
        } else {
            sourceURL = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(owner, forKey: .owner)
        try container.encode(task, forKey: .task)
        if let due {
            let formatter = ISO8601DateFormatter()
            try container.encode(formatter.string(from: due), forKey: .due)
        }
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(sourceURL?.absoluteString, forKey: .sourceURL)
    }
}
