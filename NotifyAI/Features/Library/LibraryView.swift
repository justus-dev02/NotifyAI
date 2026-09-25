//
//  LibraryView.swift
//  NotifyAI
//

import PhotosUI
import SwiftData
import SwiftUI

/// The list of notes with search, filters and import.
struct LibraryView: View {
    @Environment(AppNavigation.self) private var navigation
    @Environment(RecordingController.self) private var recording
    @Environment(\.appEnvironment) private var app

    @State private var isImporterPresented = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var isPhotoPickerPresented = false
    @State private var importError: String?
    @State private var isImporting = false

    var body: some View {
        @Bindable var navigation = navigation

        NoteList(filter: navigation.filter, searchText: navigation.searchText, selection: $navigation.selectedNoteID)
            .navigationTitle(navigation.filter.title)
            .searchable(text: $navigation.searchText, prompt: "Titel, Transkript, Zusammenfassung")
            .toolbar { toolbarContent }
            #if os(iOS)
            .safeAreaInset(edge: .bottom) {
                if !recording.isActive {
                    recordButton
                        .padding(.bottom, Theme.Spacing.small)
                }
            }
            #endif
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: DocumentImporter.supportedTypes
            ) { result in
                switch result {
                case .success(let url): importFile(at: url)
                case .failure(let error): importError = error.localizedDescription
                }
            }
            .photosPicker(isPresented: $isPhotoPickerPresented, selection: $photoSelection, matching: .images)
            .onChange(of: photoSelection) { _, item in
                guard let item else { return }
                importPhoto(item)
            }
            .alert("Import fehlgeschlagen", isPresented: Binding(presenting: $importError)) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .overlay {
                if isImporting {
                    ProgressView("Wird importiert …")
                        .padding(Theme.Spacing.large)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
                }
            }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        @Bindable var navigation = navigation

        #if os(iOS)
        ToolbarItem(placement: .topBarLeading) {
            Button("Einstellungen", systemImage: "gearshape") {
                navigation.isSettingsPresented = true
            }
        }
        #else
        ToolbarItem(placement: .primaryAction) {
            Button("Aufnahme", systemImage: "record.circle") {
                navigation.isRecorderPresented = true
            }
            .help("Neue Aufnahme starten (⇧⌘R)")
            .disabled(recording.isActive)
        }
        #endif

        ToolbarItem {
            Menu("Filter", systemImage: "line.3.horizontal.decrease") {
                Picker("Filter", selection: $navigation.filter) {
                    ForEach(LibraryFilter.allCases) { filter in
                        Label(filter.title, systemImage: filter.symbolName).tag(filter)
                    }
                }
                .pickerStyle(.inline)
            }
        }

        ToolbarItem {
            Menu("Importieren", systemImage: "square.and.arrow.down") {
                Button("Datei importieren …", systemImage: "doc.badge.plus") {
                    isImporterPresented = true
                }
                Button("Foto (Texterkennung) …", systemImage: "photo") {
                    isPhotoPickerPresented = true
                }
            }
            .help("Audiodatei, PDF oder Bild importieren")
        }
    }

    #if os(iOS)
    private var recordButton: some View {
        Button {
            navigation.isRecorderPresented = true
        } label: {
            Label("Aufnahme starten", systemImage: "mic.fill")
                .font(.headline)
                .padding(.horizontal, Theme.Spacing.large)
                .padding(.vertical, Theme.Spacing.small)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.recording)
        .controlSize(.large)
    }
    #endif

    // MARK: Import

    private func importFile(at url: URL) {
        guard let app else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                navigation.selectedNoteID = try await app.importer.importFile(at: url)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) {
        guard let app else { return }
        isImporting = true
        Task {
            defer {
                isImporting = false
                photoSelection = nil
            }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw ImportError.unreadableFile
                }
                navigation.selectedNoteID = try await app.importer.importImage(data: data)
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

// MARK: - List

/// The filtered list. A separate view so `@Query` can be rebuilt when the filter changes.
private struct NoteList: View {
    @Binding var selection: UUID?
    @Query private var notes: [Note]
    @Environment(\.appEnvironment) private var app
    @Environment(ProcessingCoordinator.self) private var processing
    @Environment(AppNavigation.self) private var navigation
    /// Identifier of the note awaiting delete confirmation.
    @State private var noteIDToDelete: UUID?
    private let isSearching: Bool

    init(filter: LibraryFilter, searchText: String, selection: Binding<UUID?>) {
        _selection = selection
        _notes = Query(filter: Self.predicate(filter: filter, searchText: searchText), sort: \Note.createdAt, order: .reverse)
        isSearching = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.notes) { note in
                        NoteRow(note: note, activity: processing.activities[note.id])
                            .tag(note.id)
                            .contextMenu { contextMenu(for: note) }
                            .swipeActions(edge: .leading) {
                                Button(note.isFavorite ? "Favorit entfernen" : "Favorit", systemImage: note.isFavorite ? "star.slash" : "star") {
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
        Button(note.isFavorite ? "Aus Favoriten entfernen" : "Zu Favoriten", systemImage: "star") {
            toggleFavorite(note)
        }
        Divider()
        Button("Löschen …", systemImage: "trash", role: .destructive) {
            noteIDToDelete = note.id
        }
    }

    private func toggleFavorite(_ note: Note) {
        note.isFavorite.toggle()
        try? app?.store.save()
    }

    private func delete(noteID: UUID) {
        noteIDToDelete = nil
        if selection == noteID {
            selection = nil
        }
        processing.cancel(noteID: noteID)
        if let note = notes.first(where: { $0.id == noteID }) {
            try? app?.store.delete(note)
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
                title = "Heute"
            } else if calendar.isDateInYesterday(note.createdAt) {
                title = "Gestern"
            } else if let days = calendar.dateComponents([.day], from: note.createdAt, to: now).day, days < 7 {
                title = "Letzte 7 Tage"
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

    private static func predicate(filter: LibraryFilter, searchText: String) -> Predicate<Note> {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let recording = NoteKind.recording.rawValue
        let favoritesOnly = filter == .favorites
        let recordingsOnly = filter == .recordings
        let importsOnly = filter == .imports

        return #Predicate<Note> { note in
            (!favoritesOnly || note.isFavorite)
                && (!recordingsOnly || note.kindRawValue == recording)
                && (!importsOnly || note.kindRawValue != recording)
                && (query.isEmpty
                    || note.title.localizedStandardContains(query)
                    || note.bodyText.localizedStandardContains(query)
                    || note.summaryOverview.localizedStandardContains(query))
        }
    }
}

// MARK: - Row

private struct NoteRow: View {
    let note: Note
    let activity: ProcessingCoordinator.Activity?

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            NoteKindIcon(kind: note.kind)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Spacing.xSmall) {
                    Text(note.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
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
                        .lineLimit(1)
                } else {
                    NoteStatusLabel(status: activity?.stage ?? note.status, progress: activity?.progress)
                }
            }
        }
        .padding(.vertical, 4)
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
