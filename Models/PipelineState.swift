//
//  PipelineState.swift
//  NotifyAI
//
//  Created by Justus on 29.09.25.
//

struct PipelineState: Codable {
    enum Stage: String, Codable {
        case none, transcribing, diarizing, chunking, summarizing, roleSummaries, mindmap, indexing, done, error
    }
    var stage: Stage = .none
    var progress: Double = 0
    var etaSeconds: Int? = nil
    var message: String? = nil
}
