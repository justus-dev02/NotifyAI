//
//  LabelSettingsSection.swift
//  NotifyAI
//

import NotifyAICore
import NotifyAIPersistence
import NotifyAIServices
import SwiftData
import SwiftUI

/// All labels with the number of notes: renaming (and merging) and removing them everywhere.
struct LabelSettingsSection: View {
    @Environment(NoteLabels.self) private var labels
    @Environment(AppNavigation.self) private var navigation
    /// Refreshes the list when notes change.
    @Query(filter: #Predicate<Note> { !$0.labelKeys.isEmpty }) private var labeledNotes: [Note]
    @State private var renaming: LabelUsage?
    @State private var newName = ""
    @State private var deleting: LabelUsage?

    var body: some View {
        let usages = labeledNotes.isEmpty ? [] : labels.all()
        Section {
            if usages.isEmpty {
                Text("Noch keine Labels. Du vergibst sie in einer Notiz unter dem Titel oder vor der Aufnahme.")
                    .foregroundStyle(.secondary)
            }
            ForEach(usages) { usage in
                HStack {
                    Label(usage.name, systemImage: "tag")
                    Spacer()
                    Text(usage.noteCount == 1 ? String(localized: "1 Notiz") : String(localized: "\(usage.noteCount) Notizen"))
                        .foregroundStyle(.secondary)
                    Menu {
                        actions(for: usage)
                    } label: {
                        Label("Optionen", systemImage: "ellipsis.circle")
                            .labelStyle(.iconOnly)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .contextMenu { actions(for: usage) }
            }
        } header: {
            Text("Labels")
        } footer: {
            Text("Labels nennen den Zusammenhang einer Notiz, etwa deine Firma, ein Projekt oder einen Kurs. „Notizen fragen“ sucht mit einem Label in der Frage nur in diesen Notizen („Samsung: Was ist noch offen?“), und die Zusammenfassung berücksichtigt es. Umbenennen auf einen vorhandenen Namen führt beide Labels zusammen.")
        }
        .alert("Label umbenennen", isPresented: Binding(presenting: $renaming)) {
            TextField("Name", text: $newName)
            Button("Abbrechen", role: .cancel) { renaming = nil }
            Button("Umbenennen") {
                if let renaming { labels.rename(renaming.name, to: newName) }
                renaming = nil
            }
        }
        .confirmationDialog(
            "Label entfernen?",
            isPresented: Binding(presenting: $deleting),
            titleVisibility: .visible,
            presenting: deleting
        ) { usage in
            Button("Von allen Notizen entfernen", role: .destructive) {
                if navigation.labelFilter.map(NoteLabel.key) == usage.id { navigation.labelFilter = nil }
                labels.delete(usage.name)
                deleting = nil
            }
            Button("Abbrechen", role: .cancel) { deleting = nil }
        } message: { usage in
            Text(usage.noteCount == 1
                ? String(localized: "„\(usage.name)“ wird von einer Notiz entfernt. Die Notiz bleibt erhalten.")
                : String(localized: "„\(usage.name)“ wird von \(usage.noteCount) Notizen entfernt. Die Notizen bleiben erhalten."))
        }
    }

    @ViewBuilder
    private func actions(for usage: LabelUsage) -> some View {
        Button("Notizen zeigen", systemImage: "line.3.horizontal.decrease") {
            navigation.filter = .all
            navigation.labelFilter = usage.name
            navigation.isSettingsPresented = false
        }
        Button("Umbenennen …", systemImage: "pencil") {
            newName = usage.name
            renaming = usage
        }
        Button("Entfernen …", systemImage: "trash", role: .destructive) { deleting = usage }
    }
}
