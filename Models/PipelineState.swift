//
//  PipelineState.swift
//  NotifyAI
//
//  Created by Justus on 29.09.25.
//

struct PipelineState: Codable {
    enum Stage: Int, Codable, CaseIterable {
        case none
        case chunking
        case transcribing
        case diarizing
        case summarizing
        case roleSummaries
        case mindmap
        case indexing
        case done
        case error
    }
    var stage: Stage = .none
    var progress: Double = 0
    var etaSeconds: Int? = nil
    var message: String? = nil
}

extension PipelineState.Stage {
    static var progression: [PipelineState.Stage] {
        [.chunking, .transcribing, .diarizing, .summarizing, .roleSummaries, .mindmap, .indexing, .done]
    }
}
