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

struct ActionItem: Codable {
    var owner: String?
    var task: String
    var due: Date?

    enum CodingKeys: String, CodingKey {
        case owner, task, due
    }

    init(owner: String? = nil, task: String, due: Date? = nil) {
        self.owner = owner
        self.task = task
        self.due = due
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        task = try container.decode(String.self, forKey: .task)
        if let dateString = try container.decodeIfPresent(String.self, forKey: .due) {
            let formatter = ISO8601DateFormatter()
            due = formatter.date(from: dateString)
        } else {
            due = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(owner, forKey: .owner)
        try container.encode(task, forKey: .task)
        if let due {
            let formatter = ISO8601DateFormatter()
            try container.encode(formatter.string(from: due), forKey: .due)
        }
    }
}
