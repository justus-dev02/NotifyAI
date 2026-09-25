//
//  PipelineState.swift
//  NotifyAI
//
//  Created by Justus on 29.09.25.
//

import Foundation

struct PipelineState: Codable, Hashable {
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

        var displayName: String {
            switch self {
            case .none: return "Bereit"
            case .chunking: return "Vorbereitung"
            case .transcribing: return "Transkription"
            case .diarizing: return "Sprechererkennung"
            case .summarizing: return "Zusammenfassung"
            case .roleSummaries: return "Rollenanalyse"
            case .mindmap: return "Mindmap"
            case .indexing: return "Indexierung"
            case .done: return "Fertig"
            case .error: return "Fehler"
            }
        }
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
