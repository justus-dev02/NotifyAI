//
//  NoteStatusLabel.swift
//  NotifyAI
//

import DesignSystem
import NotifyAICore
import SwiftUI

/// Status line for a note, with progress while it is processed.
struct NoteStatusLabel: View {
    let status: NoteStatus
    var progress: Double?

    var body: some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            if status.isProcessing {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: status.symbolName)
            }
            Text(status.displayName)
            if let progress, status.isProcessing {
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .foregroundStyle(status.tint)
    }
}
