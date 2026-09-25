//
//  EnhancedNoteDetailView.swift
//  NotifyAI
//
//  Created by AI Assistant on 23.10.25.
//  Updated for Apple Liquid Glass Design & Interactive Action Items.
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
        case mindmap = "Mindmap"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .summary: return "doc.text.fill"
            case .transcript: return "waveform"
            case .mindmap: return "point.3.filled.connected.trianglepath.dotted"
            }
        }
    }

    @State private var selectedTab: Tab = .summary
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var isExporting = false
    @State private var shareURL: URL?

    private let exportService = ExportService()

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                // Header Glass Card
                headerCard

                // Audio Player Card
                if let audioURL = note.audioURL {
                    audioSection(url: audioURL)
                }

                // Floating Liquid Glass Tab Picker
                tabPicker

                // Selected Section Content
                switch selectedTab {
                case .summary:
                    summarySection
                case .transcript:
                    transcriptSection
                case .mindmap:
                    mindmapSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .liquidGlassBackground()
        .navigationTitle(note.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        Task { await exportPDF() }
                    } label: {
                        Label("PDF exportieren", systemImage: "doc.richtext")
                    }

                    Button {
                        exportMarkdown()
                    } label: {
                        Label("Markdown exportieren", systemImage: "doc.text")
                    }

                    if let mindmap = note.mindmap {
                        Button {
                            exportMermaid(mindmap)
                        } label: {
                            Label("Mermaid Mindmap exportieren", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.indigo)
                }
            }
        }
        .sheet(item: $shareURL) { url in
            ShareSheet(activityItems: [url])
        }
    }

    // MARK: - Header Glass Card

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
                if let loc = note.location {
                    Label(loc, systemImage: "mappin.and.ellipse")
                }
            }
            .font(.caption)
            .foregroundStyle(Color.adaptiveSecondaryLabel)

            if !note.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(note.tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.purple.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.purple)
                    }
                }
            }
        }
        .liquidGlassCard(cornerRadius: 22, padding: 18)
    }

    // MARK: - Audio Section

    private func audioSection(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .font(.title3)
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
        .liquidGlassCard(cornerRadius: 22, padding: 16)
    }

    // MARK: - Tab Picker

    private var tabPicker: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { tab in
                tabButton(for: tab)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
        )
    }

    private func tabButton(for tab: Tab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(.caption)
                Text(tab.rawValue)
                    .font(.caption.bold())
            }
            .foregroundStyle(isSelected ? Color.white : Color.adaptiveLabel)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                isSelected ? Color.indigo : Color.clear,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
    }

    // MARK: - Summary Section

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let summary = note.summary {
                // Key Highlights
                if !summary.highlights.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(Color.indigo)
                            Text("Kernaussagen")
                                .font(.headline)
                                .foregroundStyle(Color.adaptiveLabel)
                        }

                        ForEach(summary.highlights, id: \.self) { highlight in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(Color.indigo)
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 6)
                                Text(highlight)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.adaptiveLabel)
                            }
                        }
                    }
                    .liquidGlassCard(cornerRadius: 20, padding: 16)
                }

                // Decisions
                if !summary.decisions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(Color.green)
                            Text("Beschlüsse & Entscheidungen")
                                .font(.headline)
                                .foregroundStyle(Color.adaptiveLabel)
                        }

                        ForEach(summary.decisions, id: \.self) { decision in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "checkmark")
                                    .font(.caption2.bold())
                                    .foregroundStyle(Color.green)
                                    .padding(.top, 4)
                                Text(decision)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.adaptiveLabel)
                            }
                        }
                    }
                    .liquidGlassCard(cornerRadius: 20, padding: 16)
                }

                // Action Items
                if !summary.actionItems.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "checklist")
                                .foregroundStyle(Color.indigo)
                            Text("Aufgaben & Action Items")
                                .font(.headline)
                                .foregroundStyle(Color.adaptiveLabel)
                        }

                        ForEach(summary.actionItems.indices, id: \.self) { index in
                            let item = summary.actionItems[index]
                            Button {
                                toggleActionItemStatus(at: index)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: item.status == .completed ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(item.status == .completed ? Color.green : Color.indigo)
                                        .font(.title3)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.task)
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                            .strikethrough(item.status == .completed)
                                            .foregroundStyle(item.status == .completed ? Color.adaptiveSecondaryLabel : Color.adaptiveLabel)
                                        if let owner = item.owner {
                                            Text("Zuständig: \(owner)")
                                                .font(.caption)
                                                .foregroundStyle(Color.adaptiveSecondaryLabel)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 3)
                        }
                    }
                    .liquidGlassCard(cornerRadius: 20, padding: 16)
                }

                // Markdown Full Report
                if !summary.markdown.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Vollständige Zusammenfassung")
                            .font(.headline)
                            .foregroundStyle(Color.adaptiveLabel)

                        Text(LocalizedStringKey(summary.markdown))
                            .font(.subheadline)
                            .lineSpacing(4)
                            .foregroundStyle(Color.adaptiveLabel)
                    }
                    .liquidGlassCard(cornerRadius: 20, padding: 16)
                }
            } else {
                Text("Keine Zusammenfassung vorhanden.")
                    .font(.subheadline)
                    .foregroundStyle(Color.adaptiveSecondaryLabel)
                    .padding(24)
            }
        }
    }

    // MARK: - Transcript Section

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if note.segments.isEmpty {
                Text("Keine Transkription vorhanden.")
                    .font(.subheadline)
                    .foregroundStyle(Color.adaptiveSecondaryLabel)
                    .padding(24)
            } else {
                ForEach(note.segments) { segment in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(segment.speakerId ?? "Sprecher")
                                .font(.caption.bold())
                                .foregroundStyle(Color.indigo)
                            Spacer()
                            Text(formatDuration(segment.start))
                                .font(.caption2)
                                .foregroundStyle(Color.adaptiveSecondaryLabel)
                        }
                        Text(segment.text)
                            .font(.subheadline)
                            .foregroundStyle(Color.adaptiveLabel)
                    }
                    .liquidGlassCard(cornerRadius: 16, padding: 14)
                }
            }
        }
    }

    // MARK: - Mindmap Section

    private var mindmapSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let mindmap = note.mindmap {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "brain.head.profile")
                            .foregroundStyle(Color.indigo)
                        Text(mindmap.root)
                            .font(.headline)
                            .foregroundStyle(Color.adaptiveLabel)
                    }

                    ForEach(mindmap.children, id: \.label) { node in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("• \(node.label)")
                                .font(.subheadline.bold())
                                .foregroundStyle(Color.indigo)

                            if let subNodes = node.children {
                                ForEach(subNodes, id: \.label) { sub in
                                    Text("    - \(sub.label)")
                                        .font(.caption)
                                        .foregroundStyle(Color.adaptiveSecondaryLabel)
                                }
                            }
                        }
                        .padding(.leading, 8)
                    }
                }
                .liquidGlassCard(cornerRadius: 20, padding: 18)
            } else {
                Text("Keine Mindmap verfügbar.")
                    .font(.subheadline)
                    .foregroundStyle(Color.adaptiveSecondaryLabel)
                    .padding(24)
            }
        }
    }

    // MARK: - Helper Methods

    private func toggleActionItemStatus(at index: Int) {
        guard var summary = note.summary, index < summary.actionItems.count else { return }
        summary.actionItems[index].status = summary.actionItems[index].status == .completed ? .open : .completed
        note.summary = summary
        notesViewModel.update(note: note)
    }

    private func exportPDF() async {
        let md = note.summary?.markdown ?? note.title
        if let pdfURL = await exportService.pdf(fromMarkdown: md, redacted: false) {
            shareURL = pdfURL
        }
    }

    private func exportMarkdown() {
        let md = note.summary?.markdown ?? note.title
        if let mdURL = exportService.exportMarkdownFile(content: md, title: note.title) {
            shareURL = mdURL
        }
    }

    private func exportMermaid(_ mindmap: Mindmap) {
        if let mmdURL = exportService.exportMermaidFile(mindmap: mindmap, title: note.title) {
            shareURL = mmdURL
        }
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

// MARK: - Share Sheet Helper
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

#Preview {
    NavigationStack {
        EnhancedNoteDetailView(note: Note(title: "Projekt-Kickoff 2026"))
            .environmentObject(ThemeManager())
            .environmentObject(NotesViewModel())
    }
}
