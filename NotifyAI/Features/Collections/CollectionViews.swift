//
//  CollectionViews.swift
//  NotifyAI
//

import DesignSystem
import NotifyAICore
import NotifyAIPersistence
import NotifyAIServices
import SwiftData
import SwiftUI

/// The notes a summary across several notes was made from; tapping one opens it.
struct CollectionSourcesView: View {
    let note: Note
    @Query private var sources: [Note]
    @Environment(AppNavigation.self) private var navigation

    init(note: Note) {
        self.note = note
        let ids = note.sourceNoteIDs
        _sources = Query(filter: #Predicate<Note> { ids.contains($0.id) }, sort: \Note.createdAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Diese Zusammenfassung wurde aus den Zusammenfassungen dieser Notizen erstellt. „Neu zusammenfassen“ liest sie erneut, mit allen Änderungen seither.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let missing = note.sourceNoteIDs.count - sources.count
            if missing > 0 {
                Label(
                    missing == 1
                        ? String(localized: "Eine Notiz wurde inzwischen gelöscht.")
                        : String(localized: "\(missing) Notizen wurden inzwischen gelöscht."),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }
            ForEach(sources) { source in
                Button {
                    navigation.selectedNoteID = source.id
                } label: {
                    HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                        NoteKindIcon(kind: source.kind)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.title)
                                .font(.body.weight(.semibold))
                                .multilineTextAlignment(.leading)
                            Text(source.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !source.summaryOverview.isEmpty {
                                Text(source.summaryOverview)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.forward")
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(Theme.Spacing.medium)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            }
        }
    }
}

/// The tasks of a collection's notes, each task once. Ticking one off ticks it off in every
/// note that mentions it.
struct CollectionTasksSection: View {
    let collection: Note
    @Environment(NoteCollections.self) private var collections
    @Environment(AppNavigation.self) private var navigation
    /// Refreshes the list when a task changes.
    @Query private var rows: [NoteTask]

    init(collection: Note) {
        self.collection = collection
        let ids = collection.sourceNoteIDs
        _rows = Query(filter: #Predicate<NoteTask> { task in task.note.flatMap { ids.contains($0.id) } == true })
    }

    var body: some View {
        let tasks = rows.isEmpty ? [] : collections.tasks(of: collection)
        ContentSection(title: "Aufgaben aus den Notizen", systemImage: "checklist", tint: .blue) {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                if tasks.isEmpty {
                    Text("In diesen Notizen wurden keine Aufgaben vereinbart.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(tasks) { task in
                    row(task)
                }
            }
        }
    }

    private func row(_ task: CollectionTask) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
            Button {
                collections.setDone(task, !task.item.isDone)
            } label: {
                Image(systemName: task.item.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.item.isDone ? Color.green : Color.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.item.isDone ? "Wieder öffnen" : "Erledigt")
            VStack(alignment: .leading, spacing: 2) {
                Text(task.item.task)
                    .strikethrough(task.item.isDone)
                    .foregroundStyle(task.item.isDone ? .secondary : .primary)
                let details = [task.item.owner, task.item.due.map { String(localized: "bis \($0)") }].compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Where it comes from; the same task in several notes is listed once.
                HStack(spacing: Theme.Spacing.small) {
                    ForEach(Array(zip(task.noteIDs, task.noteTitles)), id: \.0) { noteID, title in
                        Button(title) { navigation.selectedNoteID = noteID }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}
