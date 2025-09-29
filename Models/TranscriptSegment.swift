//
//  TranscriptSegment.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import Foundation

struct TranscriptSegment: Identifiable, Codable {
    let id: UUID
    var start: TimeInterval
    var end: TimeInterval
    var speakerId: String?   // "S1", "S2", ...
    var text: String
    init(start: TimeInterval, end: TimeInterval, speakerId: String?, text: String) {
        self.id = UUID()
        self.start = start
        self.end = end
        self.speakerId = speakerId
        self.text = text
    }
}
