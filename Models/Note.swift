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
    var location: String?
    var duration: TimeInterval?
    var audioURL: URL?
    var tags: [String]
    var participants: [String]
    var segments: [TranscriptSegment]
    var summary: Summary?
    var roleSummaries: [String: Summary]
    var mindmap: Mindmap?
    var consent: ConsentLog?
    var pipeline: PipelineState

    init(id: UUID = UUID(), title: String, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.location = nil
        self.duration = nil
        self.audioURL = nil
        self.tags = []
        self.participants = []
        self.segments = []
        self.summary = nil
        self.roleSummaries = [:]
        self.mindmap = nil
        self.consent = nil
        self.pipeline = .init()
    }
}
