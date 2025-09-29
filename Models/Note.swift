//
//  Note.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import Foundation

struct Note: Identifiable, Codable {
    let id: UUID
    var title: String
    var createdAt: Date
    var tags: [String]
    var segments: [TranscriptSegment]
    var summary: Summary?
    var consent: ConsentLog?
    init(title: String, tags: [String] = []) {
        id = UUID()
        self.title = title
        self.createdAt = Date()
        self.tags = tags
        self.segments = []
        self.summary = nil
    }
}
