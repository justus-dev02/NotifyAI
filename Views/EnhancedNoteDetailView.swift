//
//  EnhancedNoteDetailView.swift
//  NotifyAI
//
//  Created by AI Assistant on 23.10.25.
//

import SwiftUI
import AVKit

struct EnhancedNoteDetailView: View {
    @State var note: Note
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var notesViewModel: NotesViewModel
    
    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Zusammenfassung"
        case transcript = "Transkription"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .summary: return "doc.text.fill"
            case .transcript: return "text.quote"
            }
        }
    }
    
    @State private var selectedTab: Tab = .summary
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerCard
                
                if let audioURL = note.audioURL {
                    audioSection(url: audioURL)
                }
                
                tabPicker
                
                switch selectedTab {
                case .summary:
                    summarySection
                case .transcript:
                    transcriptSection
                }
            }
            .padding(20)
        }
        .background(
            LinearGradient(
                colors: [Color.adaptiveBackground, Color.indigo.opacity(0.04)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .navigationTitle(note.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(note.title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.adaptiveLabel)
                Spacer()
            }
            
            HStack(spacing: 12) {
                Label(formattedDate(note.createdAt), systemImage: "calendar")
                if let dur = note.duration {
                    Label(formatDuration(dur), systemImage: "clock")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !note.participants.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "person.2.fill")
                        .font(.caption)
                        .foregroundStyle(Color.indigo)
                    Text(note.participants.map { $0.name }.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.indigo.opacity(0.15), lineWidth: 1)
        )
    }

    private func audioSection(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.indigo)
                Text("Audio-Wiedergabe")
                    .font(.headline)
                    .foregroundStyle(Color.adaptiveLabel)
                Spacer()
            }
            
            EnhancedAudioPlayerView(
                url: url,
                isPlaying: $isPlaying,
                currentTime: $currentTime,
                duration: $duration
            )
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var tabPicker: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                        Text(tab.rawValue)
                    }
                    .font(.subheadline)
                    .fontWeight(selectedTab == tab ? .bold : .medium)
                    .foregroundStyle(selectedTab == tab ? Color.white : Color.adaptiveLabel)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        selectedTab == tab ? Color.indigo : Color.clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                }
            }
        }
        .padding(4)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let summary = note.summary {
                if !summary.highlights.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Highlights")
                            .font(.headline)
                            .foregroundStyle(Color.indigo)
                        ForEach(summary.highlights, id: \.self) { highlight in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(Color.indigo)
                                    .font(.caption)
                                    .padding(.top, 2)
                                Text(highlight)
                                    .font(.subheadline)
                            }
                        }
                    }
                    .padding(16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                if !summary.markdown.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Zusammenfassung")
                            .font(.headline)
                            .foregroundStyle(Color.adaptiveLabel)
                        Text(LocalizedStringKey(summary.markdown))
                            .font(.body)
                            .lineSpacing(4)
                    }
                    .padding(16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                if !summary.actionItems.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("To-Dos & Action Items")
                            .font(.headline)
                            .foregroundStyle(Color.indigo)
                        ForEach(summary.actionItems) { item in
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.indigo)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.task)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    if let owner = item.owner {
                                        Text("Zuständig: \(owner)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            } else {
                Text("Keine Zusammenfassung vorhanden.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(24)
            }
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if note.segments.isEmpty {
                Text("Keine Transkription vorhanden.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(24)
            } else {
                ForEach(note.segments) { segment in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(speakerName(for: segment.speakerId))
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundStyle(Color.indigo)
                            Spacer()
                            Text(formatDuration(segment.start))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(segment.text)
                            .font(.body)
                    }
                    .padding(14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    private func speakerName(for speakerId: String?) -> String {
        guard let speakerId = speakerId else { return "Sprecher" }
        return note.participants.first { $0.id.uuidString == speakerId }?.name ?? "Sprecher"
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let min = Int(seconds) / 60
        let sec = Int(seconds) % 60
        return String(format: "%02d:%02d", min, sec)
    }
}
