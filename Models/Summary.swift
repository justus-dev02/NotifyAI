//
//  Summary.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import Foundation

struct Summary: Codable, Hashable {
    var highlights: [String]
    var decisions: [String]
    var actionItems: [ActionItem]
    var risks: [String]
    var markdown: String
    var citations: [UUID]

    init(
        highlights: [String] = [],
        decisions: [String] = [],
        actionItems: [ActionItem] = [],
        risks: [String] = [],
        markdown: String = "",
        citations: [UUID] = []
    ) {
        self.highlights = highlights
        self.decisions = decisions
        self.actionItems = actionItems
        self.risks = risks
        self.markdown = markdown
        self.citations = citations
    }
}

struct ActionItem: Identifiable, Codable, Hashable {
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

    init(
        id: UUID = UUID(),
        owner: String? = nil,
        task: String,
        due: Date? = nil,
        status: Status = .open,
        sourceURL: URL? = nil
    ) {
        self.id = id
        self.owner = owner
        self.task = task
        self.due = due
        self.status = status
        self.sourceURL = sourceURL
    }
}
