//
//  PipelineChip.swift
//  NotifyAI
//
//  Created by Justus on 23.10.25.
//

import SwiftUI

struct PipelineChip: View {
    let state: PipelineState

    var body: some View {
        HStack(spacing: 6) {
            ProgressView(value: state.progress)
                .frame(width: 44)
                .tint(state.stage == .done ? .green : .indigo)
            Text(label(for: state.stage))
                .font(.caption2)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func label(for s: PipelineState.Stage) -> String {
        switch s {
        case .done: return "Fertig"
        case .transcribing: return "ASR"
        case .diarizing: return "Sprecher"
        case .summarizing: return "Summary"
        case .roleSummaries: return "Rollen"
        case .mindmap: return "Mindmap"
        case .indexing: return "Index"
        case .chunking: return "Chunks"
        case .error: return "Fehler"
        default: return "Wartet"
        }
    }
}

#Preview {
    PipelineChip(state: PipelineState(stage: .transcribing, progress: 0.45))
}
