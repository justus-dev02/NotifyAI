//
//  EnhancedNoteDetailView.swift
//  NotifyAI
//
//  Created by AI Assistant on 23.10.25.
//

import SwiftUI
import AVKit

struct EnhancedNoteDetailView: View {
    let note: Note
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var audioPlayer = AudioPlayerManager()
    @State private var selectedTab: DetailTab = .overview
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    
    enum DetailTab: String, CaseIterable, Identifiable {
        case overview, transcript, summary, mindmap, actionItems
        
        var id: String { rawValue }
        
        var title: String {
            switch self {
            case .overview: return "Übersicht"
            case .transcript: return "Transkript"
            case .summary: return "Zusammenfassung"
            case .mindmap: return "Mindmap"
            case .actionItems: return "Action Items"
            }
        }
        
        var icon: String {
            switch self {
            case .overview: return "doc.text"
            case .transcript: return "text.quote"
            case .summary: return "list.bullet.rectangle"
            case .mindmap: return "tree"
            case .actionItems: return "checkmark.circle"
            }
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                headerSection
                audioPlayerSection
                tabPicker
                contentSection
            }
            .padding(24)
        }
        .themedBackground(.primary)
        .navigationTitle(note.title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button("Export als Markdown") { exportAsMarkdown() }
                    Button("Export als PDF") { exportAsPDF() }
                    Button("Teilen") { shareNote() }
                    Divider()
                    Button("Bearbeiten") { editNote() }
                    Button("Löschen", role: .destructive) { deleteNote() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            setupAudioPlayer()
        }
    }
    
    // MARK: - Header Section
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Title and Status
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text(note.title)
                        .font(.title2)
                        .fontWeight(.bold)
                        .themedText(.primary)
                    
                    Text(metaInformation)
                        .font(.subheadline)
                        .themedText(.secondary)
                }
                
                Spacer()
                
                PipelineStatusView(state: note.pipeline)
            }
            
            // Participants
            if !note.participants.isEmpty {
                ParticipantChipsView(participants: note.participants)
            }
            
            // Tags
            if !note.tags.isEmpty {
                TagsView(tags: note.tags)
            }
        }
        .glassCard()
    }
    
    // MARK: - Audio Player Section
    private var audioPlayerSection: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "waveform")
                    .foregroundColor(AppTheme.accent)
                Text("Audio-Aufnahme")
                    .font(.headline)
                    .themedText(.primary)
                Spacer()
                if let duration = note.duration {
                    Text(formatDuration(duration))
                        .font(.caption)
                        .themedText(.secondary)
                }
            }
            
            if let audioURL = note.audioURL {
                EnhancedAudioPlayerView(url: audioURL, isPlaying: $isPlaying, currentTime: $currentTime, duration: $duration)
            } else {
                Text("Keine Audio-Datei verfügbar")
                    .font(.subheadline)
                    .themedText(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(AppTheme.secondaryBackground)
                    .cornerRadius(12)
            }
        }
        .glassCard()
    }
    
    // MARK: - Tab Picker
    private var tabPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(DetailTab.allCases) { tab in
                    Button(action: { selectedTab = tab }) {
                        HStack(spacing: 8) {
                            Image(systemName: tab.icon)
                            Text(tab.title)
                        }
                        .font(.subheadline)
                        .fontWeight(selectedTab == tab ? .semibold : .regular)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            selectedTab == tab ? AppTheme.accent : AppTheme.secondaryBackground,
                            in: Capsule()
                        )
                        .foregroundColor(selectedTab == tab ? .white : AppTheme.primaryText)
                    }
                }
            }
            .padding(.horizontal, 24)
        }
    }
    
    // MARK: - Content Section
    @ViewBuilder
    private var contentSection: some View {
        switch selectedTab {
        case .overview:
            OverviewTabView(note: note)
        case .transcript:
            TranscriptTabView(note: note)
        case .summary:
            SummaryTabView(note: note)
        case .mindmap:
            MindmapTabView(note: note)
        case .actionItems:
            ActionItemsTabView(note: note)
        }
    }
    
    // MARK: - Helper Methods
    private var metaInformation: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let dateString = formatter.string(from: note.createdAt)
        
        var components = [dateString]
        
        if let location = note.location {
            components.append(location)
        }
        
        if let duration = note.duration {
            components.append(formatDuration(duration))
        }
        
        return components.joined(separator: " • ")
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    private func setupAudioPlayer() {
        if let audioURL = note.audioURL {
            audioPlayer.setupPlayer(url: audioURL)
        }
    }
    
    private func exportAsMarkdown() {
        // Implementation for Markdown export
    }
    
    private func exportAsPDF() {
        // Implementation for PDF export
    }
    
    private func shareNote() {
        // Implementation for sharing
    }
    
    private func editNote() {
        // Implementation for editing
    }
    
    private func deleteNote() {
        // Implementation for deletion
    }
}

// MARK: - Supporting Views

struct PipelineStatusView: View {
    let state: PipelineState
    
    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: state.progress)
                .frame(width: 60)
                .tint(AppTheme.accent)
            
            Text(statusText)
                .font(.caption)
                .themedText(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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

struct ParticipantChipsView: View {
    let participants: [Participant]
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(participants) { participant in
                    HStack(spacing: 6) {
                        Image(systemName: participant.avatarSymbol)
                            .font(.caption)
                        Text(participant.name)
                            .font(.caption)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(participant.color.opacity(0.2), in: Capsule())
                    .foregroundColor(participant.color)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

struct TagsView: View {
    let tags: [String]
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(AppTheme.accent.opacity(0.2), in: Capsule())
                        .foregroundColor(AppTheme.accent)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Tab Views

struct OverviewTabView: View {
    let note: Note
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let summary = note.summary {
                SummaryCard(summary: summary)
            }
            
            if !note.highlights.isEmpty {
                HighlightsCard(highlights: note.highlights)
            }
            
            if !note.decisions.isEmpty {
                DecisionsCard(decisions: note.decisions)
            }
        }
    }
}

struct TranscriptTabView: View {
    let note: Note
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if note.segments.isEmpty {
                Text("Kein Transkript verfügbar")
                    .font(.subheadline)
                    .themedText(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(AppTheme.secondaryBackground)
                    .cornerRadius(12)
            } else {
                ForEach(note.segments) { segment in
                    TranscriptSegmentCard(segment: segment, participants: note.participants)
                }
            }
        }
    }
}

struct SummaryTabView: View {
    let note: Note
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let summary = note.summary {
                SummaryCard(summary: summary)
            } else {
                Text("Keine Zusammenfassung verfügbar")
                    .font(.subheadline)
                    .themedText(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(AppTheme.secondaryBackground)
                    .cornerRadius(12)
            }
        }
    }
}

struct MindmapTabView: View {
    let note: Note
    
    var body: some View {
        if let mindmap = note.mindmap {
            MindmapView(note: note)
        } else {
            Text("Keine Mindmap verfügbar")
                .font(.subheadline)
                .themedText(.secondary)
                .frame(maxWidth: .infinity)
                .padding()
                .background(AppTheme.secondaryBackground)
                .cornerRadius(12)
        }
    }
}

struct ActionItemsTabView: View {
    let note: Note
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if note.actionItems.isEmpty {
                Text("Keine Action Items verfügbar")
                    .font(.subheadline)
                    .themedText(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(AppTheme.secondaryBackground)
                    .cornerRadius(12)
            } else {
                ForEach(note.actionItems) { item in
                    ActionItemCard(item: item)
                }
            }
        }
    }
}

// MARK: - Card Views

struct SummaryCard: View {
    let summary: Summary
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Zusammenfassung")
                .font(.headline)
                .themedText(.primary)
            
            Text(summary.markdown)
                .font(.body)
                .themedText(.primary)
        }
        .glassCard()
    }
}

struct HighlightsCard: View {
    let highlights: [String]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Highlights")
                .font(.headline)
                .themedText(.primary)
            
            ForEach(highlights, id: \.self) { highlight in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "star.fill")
                        .foregroundColor(AppTheme.accent)
                        .font(.caption)
                    Text(highlight)
                        .font(.body)
                        .themedText(.primary)
                }
            }
        }
        .glassCard()
    }
}

struct DecisionsCard: View {
    let decisions: [String]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Entscheidungen")
                .font(.headline)
                .themedText(.primary)
            
            ForEach(decisions, id: \.self) { decision in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(AppTheme.success)
                        .font(.caption)
                    Text(decision)
                        .font(.body)
                        .themedText(.primary)
                }
            }
        }
        .glassCard()
    }
}

struct TranscriptSegmentCard: View {
    let segment: TranscriptSegment
    let participants: [Participant]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(formatTime(segment.start))
                    .font(.caption)
                    .themedText(.secondary)
                
                Spacer()
                
                if let speakerId = segment.speakerId,
                   let participant = participants.first(where: { $0.id.uuidString == speakerId }) {
                    HStack(spacing: 4) {
                        Image(systemName: participant.avatarSymbol)
                            .font(.caption)
                        Text(participant.name)
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(participant.color.opacity(0.2), in: Capsule())
                    .foregroundColor(participant.color)
                }
            }
            
            Text(segment.text)
                .font(.body)
                .themedText(.primary)
        }
        .padding(16)
        .background(AppTheme.secondaryBackground)
        .cornerRadius(12)
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct ActionItemCard: View {
    let item: ActionItem
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.task)
                    .font(.body)
                    .themedText(.primary)
                
                Spacer()
                
                StatusBadge(status: item.status)
            }
            
            if let owner = item.owner {
                HStack {
                    Image(systemName: "person.fill")
                        .font(.caption)
                    Text(owner)
                        .font(.caption)
                        .themedText(.secondary)
                }
            }
            
            if let due = item.due {
                HStack {
                    Image(systemName: "calendar")
                        .font(.caption)
                    Text(due.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .themedText(.secondary)
                }
            }
        }
        .padding(16)
        .background(AppTheme.secondaryBackground)
        .cornerRadius(12)
    }
}

struct StatusBadge: View {
    let status: ActionItem.Status
    
    var body: some View {
        Text(status.displayName)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.2), in: Capsule())
            .foregroundColor(statusColor)
    }
    
    private var statusColor: Color {
        switch status {
        case .open: return AppTheme.warning
        case .inProgress: return AppTheme.accent
        case .completed: return AppTheme.success
        case .blocked: return AppTheme.error
        }
    }
}

#Preview {
    NavigationStack {
        EnhancedNoteDetailView(note: SampleDataFactory.makeSampleNotes().first!)
    }
    .environmentObject(ThemeManager())
}
