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
}

struct ActionItem: Codable {
    var owner: String?
    var task: String
    var due: Date?
}
