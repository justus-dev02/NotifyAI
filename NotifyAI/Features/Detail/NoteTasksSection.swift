//
//  NoteTasksSection.swift
//  NotifyAI
//

import DesignSystem
import NotifyAICore
import NotifyAIPersistence
import NotifyAIServices
import SwiftUI

/// The tasks of a note: tick off, add, change and remove.
///
/// Tasks the user added or changed are kept when the note is summarized again; the others are
/// replaced by what the new summary finds (ticked-off tasks stay ticked off).
struct NoteTasksSection: View {
    let note: Note
    /// Plays the transcript position where a task was mentioned.
    let onOpen: (TimeInterval) -> Void
    @Environment(NoteLibrary.self) private var library
    @State private var editing: TaskEditing?

    var body: some View {
        let tasks = note.sortedTasks
        ContentSection(title: "Aufgaben", systemImage: "checklist", tint: .blue) {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                if tasks.isEmpty {
                    Text("In diesem Gespräch wurden keine Aufgaben vereinbart.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(tasks) { task in
                    TaskRow(
                        item: task.actionItem,
                        sourceTime: task.sourceTime,
                        onOpen: onOpen,
                        onToggle: { library.setTask(task.id, isDone: !task.isDone) },
                        onEdit: { editing = TaskEditing(task: task) },
                        onDelete: { library.deleteTask(task.id) }
                    )
                }
                Button("Aufgabe hinzufügen", systemImage: "plus.circle") {
                    editing = TaskEditing(task: nil)
                }
                .buttonStyle(.borderless)
                .disabled(!note.isEditable)
            }
        }
        .sheet(item: $editing) { editing in
            TaskEditorSheet(note: note, task: editing.task)
        }
    }
}

/// A task to change, or a new one.
private struct TaskEditing: Identifiable {
    let id = UUID()
    let task: NoteTask?
}

private struct TaskRow: View {
    let item: ActionItem
    let sourceTime: TimeInterval?
    let onOpen: (TimeInterval) -> Void
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

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
                        let details = [item.owner, item.due.map { String(localized: "bis \($0)") }].compactMap { $0 }
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
                Button {
                    onOpen(sourceTime)
                } label: {
                    Label(TimeFormatting.timestamp(sourceTime), systemImage: "play.circle")
                        .font(.caption.monospacedDigit())
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .help("Stelle im Transkript anhören")
                .accessibilityLabel("Quelle bei \(TimeFormatting.timestamp(sourceTime)) anhören")
            }

            Menu {
                actions
            } label: {
                Label("Aufgabe bearbeiten", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .contextMenu { actions }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Bearbeiten …", systemImage: "pencil", action: onEdit)
        Button("Löschen", systemImage: "trash", role: .destructive, action: onDelete)
    }
}

/// Adds a task or changes one: what, who and until when.
private struct TaskEditorSheet: View {
    let note: Note
    let task: NoteTask?
    @Environment(NoteLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var draft = TaskDraft()
    @State private var hasDueDate = false
    @State private var dueDate = Date.now

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Was ist zu tun?", text: $draft.task, axis: .vertical)
                        .lineLimit(1...4)
                }
                Section {
                    HStack {
                        TextField("Verantwortlich", text: $draft.owner)
                        if !people.isEmpty {
                            Menu {
                                ForEach(people, id: \.self) { name in
                                    Button(name) { draft.owner = name }
                                }
                            } label: {
                                Label("Person wählen", systemImage: "person.crop.circle")
                                    .labelStyle(.iconOnly)
                            }
                            .menuStyle(.button)
                            .buttonStyle(.borderless)
                            .fixedSize()
                        }
                    }
                    Toggle("Fällig am", isOn: $hasDueDate.animation())
                    if hasDueDate {
                        DatePicker("Datum", selection: $dueDate, displayedComponents: .date)
                    }
                } footer: {
                    Text("Aufgaben, die du hinzufügst oder änderst, bleiben erhalten, wenn die Notiz neu zusammengefasst wird.")
                }
                if task != nil {
                    Section {
                        Button("Aufgabe löschen", systemImage: "trash", role: .destructive) {
                            if let task { library.deleteTask(task.id) }
                            dismiss()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(task == nil ? String(localized: "Neue Aufgabe") : String(localized: "Aufgabe bearbeiten"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern", action: save)
                        .disabled(draft.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 360)
        .onAppear {
            guard let task else { return }
            draft = TaskDraft(task)
            hasDueDate = task.dueDate != nil
            dueDate = task.dueDate ?? .now
        }
    }

    /// The people of the note: participants and the speakers of the transcript.
    private var people: [String] {
        (note.participants + note.speakers.map(\.label)).reduce(into: []) { names, name in
            if !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                names.append(name)
            }
        }
    }

    private func save() {
        draft.dueDate = hasDueDate ? dueDate : nil
        let saved = if let task {
            library.updateTask(task.id, with: draft)
        } else {
            library.addTask(draft, to: note)
        }
        if saved { dismiss() }
    }
}
