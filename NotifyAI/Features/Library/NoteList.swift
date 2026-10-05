//
//  NoteList.swift
//  NotifyAI
//

import DesignSystem
import NotifyAICore
import NotifyAIPersistence
import NotifyAIServices
import SwiftData
import SwiftUI

// MARK: - List

/// The filtered list. A separate view so `@Query` can be rebuilt when the filter changes.
struct NoteList: View {
    @Binding var selection: LibrarySelection?
    @Query private var notes: [Note]
    @Environment(NoteLibrary.self) private var library
    @Environment(AppNavigation.self) private var navigation
    @Environment(TaskBoard.self) private var tasks
    /// Identifier of the note awaiting delete confirmation.
    @State private var noteIDToDelete: UUID?
    private let isSearching: Bool
    private let showsTaskRow: Bool

    init(filter: LibraryFilter, searchText: String, selection: Binding<LibrarySelection?>) {
        _selection = selection
        _notes = Query(filter: NoteQueries.library(filter: filter.listFilter, searchText: searchText), sort: \Note.createdAt, order: .reverse)
        isSearching = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        showsTaskRow = filter == .all && !isSearching
    }

    var body: some View {
        List(selection: $selection) {
            // One compact row instead of another toolbar button: it appears only when
            // summaries contain tasks, and shows how many are still open.
            if showsTaskRow, !tasks.entries.isEmpty {
                Section {
                    TaskOverviewRow(openCount: tasks.openCount)
                        .tag(LibrarySelection.tasks)
                }
            }
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.notes) { note in
                        NoteRow(note: note)
                            .tag(LibrarySelection.note(note.id))
                            .contextMenu { contextMenu(for: note) }
                            .swipeActions(edge: .leading) {
                                Button(
                                    note.isFavorite ? String(localized: "Favorit entfernen") : String(localized: "Favorit"),
                                    systemImage: note.isFavorite ? "star.slash" : "star"
                                ) {
                                    toggleFavorite(note)
                                }
                                .tint(.yellow)
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Löschen", systemImage: "trash", role: .destructive) {
                                    noteIDToDelete = note.id
                                }
                            }
                    }
                }
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .listStyle(.insetGrouped)
        #endif
        .overlay {
            if notes.isEmpty {
                if isSearching {
                    ContentUnavailableView.search
                } else {
                    ContentUnavailableView(
                        "Noch keine Notizen",
                        systemImage: "waveform",
                        description: Text("Starte eine Aufnahme oder importiere eine Audiodatei, ein PDF oder ein Foto.")
                    )
                }
            }
        }
        .confirmationDialog(
            "Notiz löschen?",
            isPresented: Binding(presenting: $noteIDToDelete),
            titleVisibility: .visible,
            presenting: noteIDToDelete
        ) { noteID in
            Button("Löschen", role: .destructive) { delete(noteID: noteID) }
            Button("Abbrechen", role: .cancel) { noteIDToDelete = nil }
        } message: { _ in
            Text("Die Aufnahme, das Transkript und die Zusammenfassung werden endgültig entfernt.")
        }
    }

    @ViewBuilder
    private func contextMenu(for note: Note) -> some View {
        Button(note.isFavorite ? String(localized: "Aus Favoriten entfernen") : String(localized: "Zu Favoriten"), systemImage: "star") {
            toggleFavorite(note)
        }
        Divider()
        Button("Löschen …", systemImage: "trash", role: .destructive) {
            noteIDToDelete = note.id
        }
    }

    private func toggleFavorite(_ note: Note) {
        library.setFavorite(!note.isFavorite, for: note)
    }

    private func delete(noteID: UUID) {
        noteIDToDelete = nil
        if selection == .note(noteID) {
            selection = nil
        }
        if let note = notes.first(where: { $0.id == noteID }) {
            library.delete(note)
        }
    }

    // MARK: Sections

    private struct DateSection {
        let title: String
        let notes: [Note]
    }

    /// Groups notes into "Heute", "Gestern", "Letzte 7 Tage" and months.
    private var sections: [DateSection] {
        let calendar = Calendar.current
        let now = Date.now
        var order: [String] = []
        var grouped: [String: [Note]] = [:]

        for note in notes {
            let title: String
            if calendar.isDateInToday(note.createdAt) {
                title = String(localized: "Heute")
            } else if calendar.isDateInYesterday(note.createdAt) {
                title = String(localized: "Gestern")
            } else if let days = calendar.dateComponents([.day], from: note.createdAt, to: now).day, days < 7 {
                title = String(localized: "Letzte 7 Tage")
            } else {
                title = note.createdAt.formatted(.dateTime.month(.wide).year())
            }
            if grouped[title] == nil {
                order.append(title)
            }
            grouped[title, default: []].append(note)
        }
        return order.map { DateSection(title: $0, notes: grouped[$0] ?? []) }
    }
}

// MARK: - Row

/// One note in the list. Reads the processing progress itself: progress updates then
/// re-render only the rows, not the whole list with its date grouping.
private struct NoteRow: View {
    let note: Note
    @Environment(ProcessingCoordinator.self) private var processing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// One line keeps the list compact; at accessibility text sizes the text wraps instead
    /// of being cut off.
    private var lineLimit: Int? { dynamicTypeSize.isAccessibilitySize ? nil : 1 }

    private var activity: ProcessingCoordinator.Activity? {
        processing.activities[note.id]
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            NoteKindIcon(kind: note.kind)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Spacing.xSmall) {
                    Text(note.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(lineLimit)
                    if note.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favorit")
                    }
                }

                if note.status == .ready {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(lineLimit)
                } else {
                    NoteStatusLabel(status: activity?.stage ?? note.status, progress: activity?.progress)
                }
            }
        }
        .padding(.vertical, 4)
        // One element per note for VoiceOver and a hit area the size of the row.
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = [note.createdAt.formatted(date: .omitted, time: .shortened)]
        if note.duration > 0 {
            parts.append(TimeFormatting.duration(note.duration))
        }
        if !note.summaryOverview.isEmpty {
            parts.append(note.summaryOverview)
        }
        return parts.joined(separator: " · ")
    }
}
