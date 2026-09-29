//
//  NoteDetailView.swift
//  NotifyAI
//

import SwiftData
import SwiftUI

/// Loads the note for an identifier. `@Query` keeps the view in sync while the note is
/// being processed in the background.
struct NoteDetailContainer: View {
    @Query private var notes: [Note]

    init(noteID: UUID) {
        _notes = Query(filter: #Predicate<Note> { $0.id == noteID })
    }

    var body: some View {
        if let note = notes.first {
            NoteDetailView(note: note)
        } else {
            ContentUnavailableView("Notiz nicht gefunden", systemImage: "questionmark.folder")
        }
    }
}

struct NoteDetailView: View {
    private enum Tab: Hashable {
        case summary, transcript
    }

    @Bindable var note: Note
    @Environment(\.appEnvironment) private var app
    @Environment(ProcessingCoordinator.self) private var processing
    @Environment(AppNavigation.self) private var navigation

    @State private var model: NoteDetailModel?
    @State private var tab: Tab = .summary
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @State private var isConfirmingDelete = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                    NoteHeader(note: note)

                    if note.status != .ready {
                        ProcessingBanner(note: note, activity: processing.activities[note.id])
                    }

                    Picker("Ansicht", selection: $tab) {
                        Text("Zusammenfassung").tag(Tab.summary)
                        Text(note.kind.hasAudio ? "Transkript" : "Text").tag(Tab.transcript)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    switch tab {
                    case .summary:
                        SummaryView(note: note, segments: model?.segments ?? []) { markerTime in
                            tab = .transcript
                            model?.play(from: max(0, markerTime - Marker.highlightPadding))
                        }
                    case .transcript:
                        if let model {
                            TranscriptView(note: note, model: model, scrollProxy: proxy)
                        }
                    }
                }
                .padding(Theme.Spacing.large)
                .frame(maxWidth: Theme.readableWidth)
                .frame(maxWidth: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let model, model.player.isLoaded {
                PlaybackBar(model: model, onAddMarker: addMarkerAtPlayback)
                    .padding(.horizontal, Theme.Spacing.medium)
                    .padding(.bottom, Theme.Spacing.small)
            }
        }
        .navigationTitle(note.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbarContent }
        .task(id: updateKey) {
            if model == nil, let app {
                model = NoteDetailModel(audioSession: app.audioSession)
            }
            await model?.update(from: note, audioURL: app?.store.audioURL(for: note))
        }
        .onDisappear {
            model?.stop()
        }
        .alert("Notiz umbenennen", isPresented: $isRenaming) {
            TextField("Titel", text: $draftTitle)
            Button("Abbrechen", role: .cancel) {}
            Button("Sichern") { rename() }
        }
        .confirmationDialog("Notiz löschen?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { delete() }
        } message: {
            Text("Die Aufnahme, das Transkript und die Zusammenfassung werden endgültig entfernt.")
        }
    }

    /// Changes whenever the model needs to re-read the note.
    private var updateKey: String {
        "\(note.statusRawValue)|\(note.transcriptData?.count ?? -1)|\(note.markersData?.count ?? -1)"
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Button(note.isFavorite ? "Aus Favoriten entfernen" : "Zu Favoriten", systemImage: note.isFavorite ? "star.fill" : "star") {
                note.isFavorite.toggle()
                save()
            }
        }
        ToolbarItem {
            ShareMenu(note: note, segments: model?.segments ?? [])
        }
        ToolbarItem {
            Menu("Mehr", systemImage: "ellipsis.circle") {
                Button("Umbenennen …", systemImage: "pencil") {
                    draftTitle = note.title
                    isRenaming = true
                }
                Button("Text kopieren", systemImage: "doc.on.doc") {
                    Clipboard.copy(note.bodyText)
                }
                .disabled(note.bodyText.isEmpty)
                Divider()
                Button("Neu zusammenfassen", systemImage: "sparkles") {
                    processing.enqueue(.resummarize(note.id))
                }
                .disabled(note.status.isProcessing || note.bodyText.isEmpty)
                if note.kind.hasAudio {
                    Button("Neu transkribieren", systemImage: "waveform") {
                        processing.enqueue(.retranscribe(note.id))
                    }
                    .disabled(note.status.isProcessing || note.status == .recording)
                }
                Divider()
                Button("Löschen …", systemImage: "trash", role: .destructive) {
                    isConfirmingDelete = true
                }
                .disabled(note.status == .recording)
            }
        }
    }

    // MARK: Actions

    private func addMarkerAtPlayback() {
        guard let model else { return }
        note.markers = note.markers + [model.markerAtPlaybackPosition()]
        save()
    }

    private func rename() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        note.title = title
        note.isTitleUserDefined = true
        save()
    }

    private func delete() {
        model?.stop()
        processing.cancel(noteID: note.id)
        navigation.selectedNoteID = nil
        try? app?.store.delete(note)
    }

    private func save() {
        try? app?.store.save()
    }
}

// MARK: - Header

private struct NoteHeader: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                NoteKindIcon(kind: note.kind, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title)
                        .font(.title2.bold())
                        .textSelection(.enabled)
                    Text(note.createdAt.formatted(date: .complete, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            FlowLayout(spacing: Theme.Spacing.small) {
                if note.duration > 0 {
                    Tag(text: TimeFormatting.duration(note.duration), systemImage: "clock")
                }
                Tag(text: note.focus.title, systemImage: note.focus.symbolName)
                Tag(text: note.language.displayName, systemImage: "globe")
                if let source = note.audioSourceDescription {
                    Tag(text: source, systemImage: note.audioSource.symbolName)
                }
                if let engine = note.transcriptionEngine {
                    Tag(text: engine.displayName, systemImage: "waveform")
                }
                if !note.markers.isEmpty {
                    Tag(text: "\(note.markers.count) markiert", systemImage: "star.fill")
                }
                ForEach(note.participants, id: \.self) { name in
                    Tag(text: name, systemImage: "person")
                }
            }
        }
    }
}

// MARK: - Processing

private struct ProcessingBanner: View {
    let note: Note
    let activity: ProcessingCoordinator.Activity?
    @Environment(ProcessingCoordinator.self) private var processing

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
            Image(systemName: status.symbolName)
                .font(.title3)
                .foregroundStyle(status.tint)
                .symbolEffect(.pulse, isActive: status.isProcessing)

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text(status.displayName)
                    .font(.headline)
                if status.isProcessing {
                    if let progress = activity?.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                    Text("Du kannst die App weiter nutzen. Die Verarbeitung läuft lokal auf diesem Gerät.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if status == .failed {
                    Text(note.statusMessage ?? "Unbekannter Fehler.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Erneut versuchen", systemImage: "arrow.clockwise") {
                        processing.enqueue(.process(note.id))
                    }
                    .buttonStyle(.bordered)
                } else if status == .recording {
                    Text("Die Aufnahme läuft noch.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.large)
        .background(status.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
    }

    private var status: NoteStatus { activity?.stage ?? note.status }
}
