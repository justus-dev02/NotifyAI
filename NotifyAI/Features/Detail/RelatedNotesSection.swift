//
//  RelatedNotesSection.swift
//  NotifyAI
//

import DesignSystem
import NotifyAIServices
import SwiftUI

/// Notes that belong together with this one: same people, topics, places or similar content.
struct RelatedNotesSection: View {
    let noteID: UUID
    @Environment(KnowledgeIndexService.self) private var knowledge
    @Environment(AppNavigation.self) private var navigation
    @State private var related: [RelatedNote] = []

    var body: some View {
        Group {
            if !related.isEmpty {
                ContentSection(title: "Verwandte Notizen", systemImage: "point.3.connected.trianglepath.dotted", tint: .teal) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                        ForEach(related) { item in
                            Button {
                                navigation.open(noteID: item.note.id)
                            } label: {
                                row(item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        // Recomputed when the index changes, e.g. after another note was processed.
        .task(id: "\(noteID)-\(knowledge.revision)") {
            related = await knowledge.related(to: noteID)
        }
    }

    private func row(_ item: RelatedNote) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
            NoteKindIcon(kind: item.note.kind, size: 32)
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                Text(item.note.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(item.note.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: Theme.Spacing.xSmall) {
                    ForEach(item.reasons, id: \.self) { reason in
                        Tag(text: reason.title, systemImage: reason.symbolName)
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
