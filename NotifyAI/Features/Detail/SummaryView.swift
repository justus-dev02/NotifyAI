//
//  SummaryView.swift
//  NotifyAI
//

import SwiftUI

/// The structured summary of a note.
struct SummaryView: View {
    let note: Note
    /// The decoded transcript, cached by `NoteDetailModel`.
    let segments: [TranscriptSegment]
    /// Jumps to a position in the transcript (marked passage or source of a summary item).
    var onOpenTime: (TimeInterval) -> Void

    @Environment(\.appEnvironment) private var app
    @Environment(ProcessingCoordinator.self) private var processing

    var body: some View {
        if let summary = note.summary {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                overview(summary)

                if !summary.keyPoints.isEmpty {
                    ContentSection(title: "Kernpunkte", systemImage: "list.bullet") {
                        SourcedBulletList(items: summary.keyPoints, tint: .accentColor, sourceTimes: summary.sourceTimes, onOpen: onOpenTime)
                    }
                }

                if !summary.actionItems.isEmpty {
                    ContentSection(title: "Aufgaben", systemImage: "checklist", tint: .blue) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                            ForEach(summary.actionItems) { item in
                                ActionItemRow(item: item, sourceTime: summary.sourceTimes[item.task], onOpen: onOpenTime) { toggle(item) }
                            }
                        }
                    }
                }

                if !summary.decisions.isEmpty {
                    ContentSection(title: "Entscheidungen", systemImage: "checkmark.seal", tint: .green) {
                        SourcedBulletList(items: summary.decisions, tint: .green, sourceTimes: summary.sourceTimes, onOpen: onOpenTime)
                    }
                }

                if !summary.openQuestions.isEmpty {
                    ContentSection(title: "Offene Fragen", systemImage: "questionmark.bubble", tint: .orange) {
                        SourcedBulletList(items: summary.openQuestions, tint: .orange, sourceTimes: summary.sourceTimes, onOpen: onOpenTime)
                    }
                }

                if !note.markers.isEmpty {
                    ContentSection(title: "Markierte Stellen", systemImage: "star.fill", tint: Theme.marker) {
                        markedPassages
                    }
                }

                if !summary.topics.isEmpty {
                    ContentSection(title: "Themen", systemImage: "square.stack.3d.up", tint: .purple) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                            ForEach(summary.topics) { topic in
                                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                                    Text(topic.title).font(.subheadline.weight(.semibold))
                                    BulletList(items: topic.points)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                footer(summary)
            }
        } else if note.status.isProcessing || note.status == .recording {
            ContentUnavailableView(
                "Zusammenfassung folgt",
                systemImage: "sparkles",
                description: Text("Sobald das Transkript fertig ist, wird die Zusammenfassung erstellt.")
            )
        } else {
            ContentUnavailableView {
                Label("Keine Zusammenfassung", systemImage: "sparkles")
            } description: {
                Text("Für diese Notiz wurde noch keine Zusammenfassung erstellt.")
            } actions: {
                Button("Zusammenfassen") {
                    processing.enqueue(.resummarize(note.id))
                }
                .disabled(note.bodyText.isEmpty)
            }
        }
    }

    private func overview(_ summary: NoteSummary) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Überblick")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(summary.overview)
                .font(.title3)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !summary.keywords.isEmpty {
                FlowLayout(spacing: Theme.Spacing.xSmall) {
                    ForEach(summary.keywords, id: \.self) { keyword in
                        Tag(text: keyword, systemImage: "tag")
                    }
                }
                .padding(.top, Theme.Spacing.xSmall)
            }
        }
    }

    private var markedPassages: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            ForEach(note.markers) { marker in
                Button {
                    onOpenTime(marker.time)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
                        Text(TimeFormatting.timestamp(marker.time))
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Theme.marker)
                        Text(passage(for: marker))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                        Spacer(minLength: 0)
                        Image(systemName: "play.circle")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Spielt die markierte Stelle ab")
            }
        }
    }

    private func passage(for marker: Marker) -> String {
        let text = Transcript.text(in: marker.highlightRange(duration: note.duration), of: segments)
        return text.isEmpty ? "Keine Sprache an dieser Stelle" : "„\(text)“"
    }

    private func footer(_ summary: NoteSummary) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            switch summary.source {
            case .appleIntelligence:
                Label("Erstellt mit Apple Intelligence auf diesem Gerät. Prüfe wichtige Details im Transkript.", systemImage: "apple.intelligence")
            case .extractive:
                Label("Einfache Zusammenfassung aus den wichtigsten Sätzen.", systemImage: "text.line.first.and.arrowtriangle.forward")
                if let reason = summary.fallbackReason {
                    Text(reason)
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func toggle(_ item: ActionItem) {
        guard var summary = note.summary, let index = summary.actionItems.firstIndex(where: { $0.id == item.id }) else { return }
        summary.actionItems[index].isDone.toggle()
        note.summary = summary
        try? app?.store.save()
    }
}

private struct ActionItemRow: View {
    let item: ActionItem
    let sourceTime: TimeInterval?
    let onOpen: (TimeInterval) -> Void
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
            Button(action: onToggle) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
                    Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.isDone ? Color.green : Color.secondary)
                        .font(.title3)
                        .contentTransition(.symbolEffect(.replace))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.task)
                            .strikethrough(item.isDone)
                            .foregroundStyle(item.isDone ? .secondary : .primary)
                            .multilineTextAlignment(.leading)
                        let details = [item.owner, item.due.map { "bis \($0)" }].compactMap { $0 }
                        if !details.isEmpty {
                            Text(details.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(item.isDone ? .isSelected : [])

            if let sourceTime {
                SourceTimeButton(time: sourceTime) { onOpen(sourceTime) }
            }
        }
    }
}

/// A bullet list whose items link to the transcript position that supports them.
private struct SourcedBulletList: View {
    let items: [String]
    var tint: Color = .secondary
    let sourceTimes: [String: TimeInterval]
    let onOpen: (TimeInterval) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(tint)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    Text(item)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let time = sourceTimes[item] {
                        SourceTimeButton(time: time) { onOpen(time) }
                    }
                }
            }
        }
    }
}

/// "▶ 12:34": plays the transcript position a summary item is based on.
private struct SourceTimeButton: View {
    let time: TimeInterval
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(TimeFormatting.timestamp(time), systemImage: "play.circle")
                .font(.caption.monospacedDigit())
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderless)
        .help("Stelle im Transkript anhören")
        .accessibilityLabel("Quelle bei \(TimeFormatting.timestamp(time)) anhören")
    }
}
