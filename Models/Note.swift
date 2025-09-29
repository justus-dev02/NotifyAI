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
    var consent: ConsentLog?
    var pipeline: PipelineState

    init(title: String) {
        id = UUID(); self.title = title
        createdAt = Date(); location = nil; duration = nil; audioURL = nil
        tags = []; participants = []; segments = []
        summary = nil; roleSummaries = [:]
        consent = nil; pipeline = .init()
    }
}
