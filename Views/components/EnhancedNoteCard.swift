//
//  EnhancedNoteCard.swift
//  NotifyAI
//
//  Created by AI Assistant on 23.10.25.
//  Updated for Liquid Glass Design.
//

import SwiftUI

struct EnhancedNoteCard: View {
    let note: Note
    @EnvironmentObject var themeManager: ThemeManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header Row: Badge & Status
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: note.sourceType.icon)
                        .font(.system(size: 11, weight: .semibold))
                    Text(note.sourceType.displayName)
                        .font(.caption2.bold())
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.indigo.opacity(0.12), in: Capsule())
                .foregroundStyle(Color.indigo)
                
                Spacer()
                
                if note.pipeline.stage != .done {
                    PipelineStatusChip(state: note.pipeline)
                } else if let duration = note.duration {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform")
                            .font(.caption2)
                        Text(formatDuration(duration))
                            .font(.caption2.bold())
                    }
                    .foregroundStyle(Color.adaptiveSecondaryLabel)
                }
            }
            
            // Title
            Text(note.title)
                .font(.headline)
                .fontWeight(.bold)
                .foregroundStyle(Color.adaptiveLabel)
                .lineLimit(2)
            
            // Summary Preview
            if let summary = note.summary, !summary.markdown.isEmpty {
                Text(cleanSummaryPreview(summary.markdown))
                    .font(.subheadline)
                    .foregroundStyle(Color.adaptiveSecondaryLabel)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            } else if !note.segments.isEmpty {
                Text(note.segments.map(\.text).joined(separator: " "))
                    .font(.subheadline)
                    .foregroundStyle(Color.adaptiveSecondaryLabel)
                    .lineLimit(2)
            }
            
            // Tags Row
            if !note.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(note.tags.prefix(3), id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.purple.opacity(0.1), in: Capsule())
                            .foregroundStyle(Color.purple)
                    }
                }
            }
            
            // Footer: Timestamp & Action Items indicator
            HStack {
                Text(formatDate(note.createdAt))
                    .font(.caption2)
                    .foregroundStyle(Color.adaptiveTertiaryLabel)
                
                Spacer()
                
                if let actionCount = note.summary?.actionItems.count, actionCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.indigo)
                        Text("\(actionCount) Aufgaben")
                            .font(.caption2.bold())
                            .foregroundStyle(Color.indigo)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.indigo.opacity(0.08), in: Capsule())
                }
            }
        }
        .liquidGlassCard(cornerRadius: 22, padding: 16)
    }
    
    private func cleanSummaryPreview(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: "### 📝 Executive Summary\n", with: "")
            .replacingOccurrences(of: "### 📝 Zusammenfassung\n", with: "")
            .replacingOccurrences(of: "#### 💡 Wichtigste Erkenntnisse\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Pipeline Status Chip

struct PipelineStatusChip: View {
    let state: PipelineState
    
    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            
            Text(state.stage.displayName)
                .font(.caption2.bold())
                .foregroundStyle(Color.indigo)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.indigo.opacity(0.1), in: Capsule())
    }
}
