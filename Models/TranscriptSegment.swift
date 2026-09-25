//
//  TranscriptSegment.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import Foundation

struct TranscriptSegment: Identifiable, Codable, Hashable {
    let id: UUID
    var start: TimeInterval
    var end: TimeInterval
    var speakerId: String?
    var text: String

    init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval, speakerId: String? = nil, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.speakerId = speakerId
        self.text = text
    }
}
