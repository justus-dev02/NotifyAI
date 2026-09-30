//
//  LibraryView.swift
//  NotifyAI
//

import DesignSystem
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

        NoteList(filter: navigation.filter, searchText: navigation.searchText, selection: $navigation.selection)
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
            Button("Notizen fragen", systemImage: "bubble.left.and.text.bubble.right") {
                navigation.isChatPresented = true
            }
            .keyboardShortcut("k", modifiers: .command)
            .help("Fragen zu allen Notizen stellen (⌘K)")
        }

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
