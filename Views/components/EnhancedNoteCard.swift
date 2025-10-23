//
//  EnhancedNoteCard.swift
//  NotifyAI
//
//  Created by AI Assistant on 23.10.25.
//

import SwiftUI

struct EnhancedNoteCard: View {
    let note: Note
    @EnvironmentObject var themeManager: ThemeManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text(note.title)
                        .font(.headline)
                        .themedText(.primary)
                        .lineLimit(2)
                    
                    Text(metaInformation)
                        .font(.caption)
                        .themedText(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 8) {
                    PipelineStatusChip(state: note.pipeline)
                    
                    if note.isFavorite {
                        Image(systemName: "heart.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            
            // Tags
            if !note.tags.isEmpty {
                TagsRow(tags: note.tags)
            }
            
            // Participants
            if !note.participants.isEmpty {
                ParticipantsRow(participants: note.participants)
            }
            
            // Summary Preview
            if let summary = note.summary {
                Text(summary.markdown.prefix(120))
                    .font(.subheadline)
                    .themedText(.secondary)
                    .lineLimit(3)
            }
            
            // Highlights
            if !note.highlights.isEmpty {
                HighlightsPreview(highlights: note.highlights)
            }
            
            // Footer
            HStack {
                HStack(spacing: 16) {
                    Label("\(note.segments.count) Segmente", systemImage: "text.quote")
                        .font(.caption)
                        .themedText(.secondary)
                    
                    if let duration = note.duration {
                        Label(formatDuration(duration), systemImage: "clock")
                            .font(.caption)
                            .themedText(.secondary)
                    }
                }
                
                Spacer()
                
                HStack(spacing: 12) {
                    Button(action: { /* Share */ }) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { /* Favorite */ }) {
                        Image(systemName: note.isFavorite ? "heart.fill" : "heart")
                            .font(.caption)
                            .foregroundColor(note.isFavorite ? .red : AppTheme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .glassCard()
    }
    
    private var metaInformation: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let dateString = formatter.string(from: note.createdAt)
        
        var components = [dateString]
        
        if let location = note.location {
            components.append(location)
        }
        
        components.append(note.sourceType.displayName)
        
        return components.joined(separator: " • ")
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Supporting Views

struct PipelineStatusChip: View {
    let state: PipelineState
    
    var body: some View {
        HStack(spacing: 6) {
            ProgressView(value: state.progress)
                .frame(width: 40)
                .tint(AppTheme.accent)
            
            Text(statusText)
                .font(.caption2)
                .themedText(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(AppTheme.secondaryBackground)
        .cornerRadius(8)
    }
    
    private var statusText: String {
        switch state.stage {
        case .done: return "Fertig"
        case .transcribing: return "Transkription"
        case .diarizing: return "Sprecher"
        case .summarizing: return "Zusammenfassung"
        case .roleSummaries: return "Rollen"
        case .mindmap: return "Mindmap"
        case .indexing: return "Indexierung"
        case .error: return "Fehler"
        default: return "Verarbeitung"
        }
    }
}

struct TagsRow: View {
    let tags: [String]
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags.prefix(5), id: \.self) { tag in
                    Text(tag)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AppTheme.accent.opacity(0.2), in: Capsule())
                        .foregroundColor(AppTheme.accent)
                }
                
                if tags.count > 5 {
                    Text("+\(tags.count - 5)")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AppTheme.secondaryBackground, in: Capsule())
                        .themedText(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

struct ParticipantsRow: View {
    let participants: [Participant]
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(participants.prefix(3)) { participant in
                    HStack(spacing: 4) {
                        Image(systemName: participant.avatarSymbol)
                            .font(.caption2)
                        Text(participant.name)
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(participant.color.opacity(0.2), in: Capsule())
                    .foregroundColor(participant.color)
                }
                
                if participants.count > 3 {
                    Text("+\(participants.count - 3)")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AppTheme.secondaryBackground, in: Capsule())
                        .themedText(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

struct HighlightsPreview: View {
    let highlights: [String]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "star.fill")
                    .foregroundColor(AppTheme.accent)
                    .font(.caption)
                Text("Highlights")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .themedText(.primary)
            }
            
            ForEach(highlights.prefix(2), id: \.self) { highlight in
                Text("• \(highlight)")
                    .font(.caption)
                    .themedText(.secondary)
                    .lineLimit(1)
            }
            
            if highlights.count > 2 {
                Text("+\(highlights.count - 2) weitere")
                    .font(.caption)
                    .themedText(.secondary)
            }
        }
    }
}

#Preview {
    VStack {
        EnhancedNoteCard(note: SampleDataFactory.makeSampleNotes().first!)
        Spacer()
    }
    .padding()
    .environmentObject(ThemeManager())
}
