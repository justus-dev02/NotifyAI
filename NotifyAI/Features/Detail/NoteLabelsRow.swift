//
//  NoteLabelsRow.swift
//  NotifyAI
//

import DesignSystem
import NotifyAICore
import NotifyAIPersistence
import NotifyAIServices
import SwiftUI

/// The labels of a note, with adding and removing.
///
/// A label names the context the text often does not say ("Samsung", "Projekt Atlas"). The
/// search uses it right away ("Samsung: Was wurde zum Budget entschieden?"); the summary the
/// next time the note is summarized.
struct NoteLabelsRow: View {
    let note: Note
    @State private var isAdding = false

    var body: some View {
        FlowLayout(spacing: Theme.Spacing.small) {
            ForEach(note.labels, id: \.self) { label in
                LabelChip(name: label, note: note)
            }
            Button {
                isAdding = true
            } label: {
                Label(note.labels.isEmpty ? String(localized: "Label hinzufügen") : String(localized: "Label"), systemImage: "tag")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)
            .help("Label hinzufügen, z. B. deine Firma oder ein Projekt")
            .popover(isPresented: $isAdding, arrowEdge: .bottom) {
                LabelPicker(note: note)
            }
        }
    }
}

/// A label of the note; the menu removes it.
private struct LabelChip: View {
    let name: String
    let note: Note
    @Environment(NoteLabels.self) private var labels

    var body: some View {
        Menu {
            Button("Label entfernen", systemImage: "tag.slash", role: .destructive) {
                labels.remove(name, from: note)
            }
        } label: {
            Tag(text: name, systemImage: "tag.fill", tint: .accentColor)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Label \(name)")
    }
}

/// Adds a new label or one that other notes already have.
private struct LabelPicker: View {
    let note: Note
    @Environment(NoteLabels.self) private var labels
    @Environment(\.dismiss) private var dismiss
    @State private var newLabel = ""
    @State private var known: [LabelUsage] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack {
                TextField("Neues Label", text: $newLabel)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add(newLabel) }
                Button("Hinzufügen") { add(newLabel) }
                    .disabled(NoteLabel.normalized(newLabel) == nil)
            }
            let suggestions = suggestions
            if !suggestions.isEmpty {
                Text("Vorhandene Labels")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: Theme.Spacing.small) {
                    ForEach(suggestions) { usage in
                        Button(usage.name) { add(usage.name) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
            Text("Ein Label nennt den Zusammenhang, den der Text oft nicht sagt, etwa deine Firma, ein Projekt oder einen Kurs. „Notizen fragen“ findet so z. B. mit „Samsung: Was wurde zum Budget entschieden?“ nur diese Notizen; die Zusammenfassung berücksichtigt das Label beim nächsten Zusammenfassen.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.large)
        .frame(width: 340)
        .onAppear { known = labels.all() }
    }

    /// Labels of other notes this note does not have yet, matching what is typed.
    private var suggestions: [LabelUsage] {
        let own = Set(note.labels.map(NoteLabel.key))
        let typed = NoteLabel.key(newLabel)
        return known.filter { !own.contains($0.id) && (typed.isEmpty || $0.id.contains(typed)) }.prefix(12).map { $0 }
    }

    private func add(_ label: String) {
        guard labels.add(label, to: note) else { return }
        dismiss()
    }
}
