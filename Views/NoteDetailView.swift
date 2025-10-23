import SwiftUI

struct NoteDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case transcript
        case summary
        case mindmap

        var id: String { rawValue }

        var label: String {
            switch self {
            case .transcript: return "Transkription"
            case .summary: return "Zusammenfassung"
            case .mindmap: return "Mindmap"
            }
        }
    }

    let note: Note
    var initialTab: Tab = .summary

    @State private var selectedTab: Tab
    @State private var selectedRole: String
    @EnvironmentObject var appState: AppState

    init(note: Note, initialTab: Tab = .summary) {
        self.note = note
        self.initialTab = initialTab
        _selectedTab = State(initialValue: initialTab)
        _selectedRole = State(initialValue: note.roleSummaries.keys.sorted().first ?? "Sales")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                tabPicker
                content
            }
            .padding(24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(note.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(metaLine(note))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ParticipantRow(participants: note.participants)
                }
                Spacer()
                Menu {
                    Button("Export als Markdown") {}
                    Button("Export als PDF") {}
                    Button("Action Items → Erinnerungen") {}
                    Button("Action Items → Kalender") {}
                    Button("Mindmap als Mermaid exportieren") {}
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .labelStyle(.titleAndIcon)
                }
            }

            GlassCard {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pipeline")
                            .font(.headline)
                        PipelineStepList(state: note.pipeline)
                    }
                    Spacer()
                    AskYourNotesPanel(note: note)
                        .frame(maxWidth: 260)
                }
            }
        }
    }

    private var tabPicker: some View {
        Picker("Ansicht", selection: $selectedTab) {
            ForEach(Tab.allCases) { tab in
                Text(tab.label).tag(tab)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .transcript:
            transcriptView
        case .summary:
            summaryView
        case .mindmap:
            MindmapView(note: note)
        }
    }

    private var transcriptView: some View {
        VStack(alignment: .leading, spacing: 16) {
            AudioPlayerView(url: note.audioURL ?? URL(string: "https://example.com/placeholder.mp3")!)
            HStack {
                TextField("Transkript durchsuchen", text: .constant(""))
                    .textFieldStyle(.roundedBorder)
                Toggle("Nur Treffer", isOn: .constant(false))
                    .toggleStyle(.switch)
            }

            ForEach(note.segments) { segment in
                TranscriptSegmentView(segment: segment, participants: note.participants)
            }
        }
    }

    private var summaryView: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let summary = note.summary {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Kurzfassung")
                        .font(.headline)
                    Text(summary.markdown)
                }

                roleSwitcher

                SummarySection(title: "Highlights", items: summary.highlights)
                SummarySection(title: "Decisions", items: summary.decisions)
                ActionItemSection(items: summary.actionItems)
                SummarySection(title: "Risiken", items: summary.risks)
            }

            if !note.relatedNoteIDs.isEmpty {
                SummarySection(title: "Ähnliche Notizen", items: note.relatedNoteIDs.map { $0.uuidString.prefix(8) + "…" })
            }
        }
    }

    private var roleSwitcher: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rollenspezifische Ausgabe")
                .font(.headline)
            Picker("Rolle", selection: $selectedRole) {
                ForEach(note.roleSummaries.keys.sorted(), id: \.self) { key in
                    Text(key).tag(key)
                }
            }
            .pickerStyle(.segmented)

            if let roleSummary = note.roleSummaries[selectedRole] {
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Ausgabe für \(selectedRole)")
                            .font(.headline)
                        Text(roleSummary.markdown)
                    }
                }
            }
        }
    }

    private func metaLine(_ note: Note) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let dateString = formatter.string(from: note.createdAt)
        let duration = note.duration.map { String(format: "%.0f min", $0/60) } ?? "–"
        return [dateString, note.location ?? "Ort unbekannt", duration].joined(separator: " · ")
    }
}

private struct ParticipantRow: View {
    let participants: [Participant]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(participants) { participant in
                    Label {
                        Text(participant.name)
                    } icon: {
                        Image(systemName: participant.avatarSymbol)
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(participant.color.opacity(0.15), in: Capsule())
                }
            }
        }
    }
}

private struct PipelineStepList: View {
    let state: PipelineState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(PipelineState.Stage.progression, id: \.self) { stage in
                HStack {
                    Image(systemName: icon(for: stage, current: state.stage))
                        .foregroundStyle(color(for: stage, current: state.stage))
                    Text(label(for: stage))
                        .font(.caption)
                    Spacer()
                    if stage == state.stage {
                        ProgressView(value: state.progress)
                            .frame(width: 80)
                    }
                }
            }
        }
    }

    private func icon(for stage: PipelineState.Stage, current: PipelineState.Stage) -> String {
        if stage == current { return "circle.dashed.inset.filled" }
        if stage.rawValue < current.rawValue { return "checkmark.circle.fill" }
        return "circle"
    }

    private func color(for stage: PipelineState.Stage, current: PipelineState.Stage) -> Color {
        if stage == current { return .accentColor }
        if stage.rawValue < current.rawValue { return .green }
        return .secondary
    }

    private func label(for stage: PipelineState.Stage) -> String {
        switch stage {
        case .chunking: return "Sprache analysiert"
        case .transcribing: return "Diarization"
        case .diarizing: return "Sprecher"
        case .summarizing: return "TODOs"
        case .roleSummaries: return "Kurz-Summary"
        case .mindmap: return "Mindmap"
        case .indexing: return "Index"
        case .done: return "Fertig"
        case .error: return "Fehler"
        case .none: return "Kein Status"
        }
    }
}

private struct SummarySection: View {
    let title: String
    let items: [String]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.accentColor)
                        Text(item)
                    }
                }
            }
        }
    }
}

private struct ActionItemSection: View {
    let items: [ActionItem]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Action Items")
                    .font(.headline)
                ForEach(items) { item in
                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(item.task)
                                    .font(.subheadline)
                                Spacer()
                                NoteStatusBadge(status: item.status)
                            }
                            HStack(spacing: 12) {
                                if let owner = item.owner {
                                    Label(owner, systemImage: "person.fill")
                                        .font(.caption)
                                }
                                if let due = item.due {
                                    Label(due.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                                        .font(.caption)
                                }
                                if let url = item.sourceURL {
                                    Link(destination: url) {
                                        Label("Quelle", systemImage: "link")
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct NoteStatusBadge: View {
    let status: ActionItem.Status

    var body: some View {
        Text(status.displayName)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var color: Color {
        switch status {
        case .open: return .orange
        case .inProgress: return .blue
        case .completed: return .green
        case .blocked: return .red
        }
    }
}

private struct AskYourNotesPanel: View {
    @State private var prompt: String = "Was sind die Risiken für das Leadership-Team?"
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask your Notes")
                .font(.headline)
            TextField("Frage stellen", text: $prompt, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
            Button {
                // Trigger local RAG pipeline
            } label: {
                Label("Antwort generieren", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Letzte Antwort")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("• Risiko: Lieferverzug wegen fehlender Freigabe (Zitat 12:32)\n• Nächste Schritte: PM @ Lea informiert Stakeholder")
                    .font(.caption)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
}

private struct TranscriptSegmentView: View {
    let segment: TranscriptSegment
    let participants: [Participant]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(timeString(segment.start))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let speakerId = segment.speakerId,
                   let participant = participants.first(where: { $0.id.uuidString == speakerId || $0.name == speakerId }) {
                    Label(participant.name, systemImage: participant.avatarSymbol)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(participant.color.opacity(0.2), in: Capsule())
                }
            }
            Text(segment.text)
            HStack {
                Button("Bereich korrigieren") {}
                Spacer()
                Button("Neu zusammenfassen") {}
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Divider()
        }
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

#Preview {
    var note = Note(title: "Vertriebscall")
    note.participants = [Participant(name: "Lea", role: "AE", colorHex: "#6E5DE7"), Participant(name: "Tim", role: "PM", colorHex: "#65D6FF")]
    note.summary = Summary(highlights: ["Kunde möchte Pilot verlängern"], decisions: ["Preisnachlass 10%"], actionItems: [ActionItem(owner: "Lea", task: "Folgeangebot senden", status: .inProgress)], risks: ["Budget-Freigabe fehlt"], markdown: "Kurz-Summary")
    note.roleSummaries = ["Sales": Summary(markdown: "Sales-Fokus auf Deal-Close."), "Leadership": Summary(markdown: "Achte auf Budget.")]
    note.segments = [TranscriptSegment(start: 12, end: 60, speakerId: note.participants.first?.id.uuidString, text: "Hallo zusammen, wir starten den Call."), TranscriptSegment(start: 62, end: 120, speakerId: note.participants.last?.id.uuidString, text: "Budget Approval steht noch aus.")]
    note.pipeline = .init(stage: .summarizing, progress: 0.4)
    return NavigationStack { NoteDetailView(note: note) }
}
