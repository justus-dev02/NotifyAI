//
//  TaskOverviewView.swift
//  NotifyAI
//

import DesignSystem
import NotifyAICore
import SwiftUI

/// The entry in the library that opens the task overview.
struct TaskOverviewRow: View {
    let openCount: Int

    var body: some View {
        Label {
            Text("Offene Aufgaben")
                .font(.body.weight(.semibold))
        } icon: {
            Image(systemName: "checklist")
                .foregroundStyle(.tint)
        }
        .badge(openCount)
        .padding(.vertical, 2)
    }
}

/// All tasks of all summaries, grouped by when they are due.
///
/// Deliberately plain: one list, one filter menu in the toolbar (person, due date, done
/// tasks) and a one-line summary of the active filters. Tapping a task's note opens it at
/// the moment the task was mentioned.
struct TaskOverviewView: View {
    @Environment(TaskBoard.self) private var board
    @Environment(AppNavigation.self) private var navigation
    @State private var filter = TaskFilter()

    var body: some View {
        let now = Date.now
        let sections = sections(now: now)

        List {
            if filter.isActive {
                activeFilterSummary
            }
            ForEach(sections, id: \.bucket) { section in
                Section {
                    ForEach(section.entries) { entry in
                        TaskEntryRow(entry: entry) {
                            board.setDone(entry, !entry.item.isDone)
                        } onOpenNote: {
                            navigation.open(noteID: entry.noteID, at: entry.sourceTime.map { max(0, $0 - Marker.highlightPadding) })
                        }
                    }
                } header: {
                    SectionHeader(verbatim: section.bucket?.title ?? String(localized: "Erledigt"))
                }
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #else
        .listStyle(.insetGrouped)
        #endif
        .overlay {
            if sections.isEmpty {
                ContentUnavailableView(
                    filter.isActive ? String(localized: "Keine passenden Aufgaben") : String(localized: "Keine offenen Aufgaben"),
                    systemImage: "checklist.checked",
                    description: Text(filter.isActive
                        ? String(localized: "Ändere die Filter, um weitere Aufgaben zu sehen.")
                        : String(localized: "Aufgaben aus deinen Zusammenfassungen erscheinen hier."))
                )
            }
        }
        .navigationTitle("Aufgaben")
        .toolbar {
            ToolbarItem {
                filterMenu
            }
        }
        .animation(.default, value: board.entries)
    }

    // MARK: - Sections

    private struct TaskSection {
        /// `nil` for done tasks.
        let bucket: TaskDueBucket?
        let entries: [TaskEntry]
    }

    private func sections(now: Date) -> [TaskSection] {
        let visible = board.entries.filter { filter.matches($0, now: now) }
        let open = Dictionary(grouping: visible.filter { !$0.item.isDone }) { TaskDueBucket.bucket(for: $0.dueDate, now: now) }
        var result = TaskDueBucket.allCases.compactMap { bucket in
            open[bucket].map { TaskSection(bucket: bucket, entries: $0) }
        }
        let done = visible.filter(\.item.isDone)
        if !done.isEmpty {
            result.append(TaskSection(bucket: nil, entries: done))
        }
        return result
    }

    // MARK: - Filters

    private var filterMenu: some View {
        Menu {
            Picker("Person", selection: $filter.owner) {
                Text("Alle Personen").tag(TaskFilter.Owner.everyone)
                ForEach(board.owners, id: \.key) { owner in
                    Text(owner.openCount > 0 ? "\(owner.name) (\(owner.openCount))" : owner.name)
                        .tag(TaskFilter.Owner.person(key: owner.key))
                }
                Text("Ohne Zuständige").tag(TaskFilter.Owner.unassigned)
            }
            Picker("Fällig", selection: $filter.due) {
                Text("Jederzeit").tag(TaskDueBucket?.none)
                ForEach(TaskDueBucket.allCases) { bucket in
                    Text(bucket.title).tag(TaskDueBucket?.some(bucket))
                }
            }
            Divider()
            Toggle("Erledigte anzeigen", isOn: $filter.showsDone)
        } label: {
            Label("Filter", systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .help("Aufgaben nach Person und Fälligkeit filtern")
    }

    private var activeFilterSummary: some View {
        HStack {
            Text(filterDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Zurücksetzen") {
                filter = TaskFilter()
            }
            .font(.subheadline)
        }
    }

    private var filterDescription: String {
        var parts: [String] = []
        switch filter.owner {
        case .everyone: break
        case .unassigned: parts.append(String(localized: "Ohne Zuständige"))
        case .person(let key): parts.append(board.owners.first { $0.key == key }?.name ?? key)
        }
        if let due = filter.due {
            parts.append(due.title)
        }
        if filter.showsDone {
            parts.append(String(localized: "mit erledigten"))
        }
        return parts.joined(separator: " · ")
    }
}

/// One task: tick box, text, owner and due date, and the note it comes from.
///
/// Two targets of at least 44 × 44 points: the tick box, and the rest of the row, which
/// opens the note at the moment the task was mentioned.
private struct TaskEntryRow: View {
    let entry: TaskEntry
    let onToggle: () -> Void
    let onOpenNote: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.small) {
            Button(action: onToggle) {
                Image(systemName: entry.item.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(entry.item.isDone ? Color.green : Color.secondary)
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.item.isDone ? String(localized: "Als offen markieren") : String(localized: "Als erledigt markieren"))
            .accessibilityValue(entry.item.task)

            Button(action: onOpenNote) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.item.task)
                        .strikethrough(entry.item.isDone)
                        .foregroundStyle(entry.item.isDone ? .secondary : .primary)
                    if !details.isEmpty {
                        Text(details)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Label(entry.noteTitle, systemImage: "arrow.up.forward.square")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Öffnet die Notiz an der Stelle, an der die Aufgabe genannt wurde")
            .help("Notiz an der Stelle öffnen, an der die Aufgabe genannt wurde")
        }
    }

    /// "Anna · bis Freitag (3. Okt.)".
    private var details: String {
        var parts: [String] = []
        if let owner = entry.item.owner, !owner.isEmpty {
            parts.append(owner)
        }
        if let due = entry.item.due, !due.isEmpty {
            if let date = entry.dueDate, !Self.mentionsDate(due) {
                parts.append(String(localized: "bis \(due) (\(date.formatted(.dateTime.day().month(.abbreviated))))"))
            } else {
                parts.append(String(localized: "bis \(due)"))
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Whether the deadline text already contains a calendar date.
    private static func mentionsDate(_ text: String) -> Bool {
        text.contains(where: \.isNumber)
    }
}
