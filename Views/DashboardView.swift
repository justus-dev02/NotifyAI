//
//  DashboardView.swift
//  NotifyAI
//
//  Created by Justus on 29.09.25.
//

import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    searchArea
                    quickActions
                    sectionHeader(title: "Aktuelle Notizen")
                    LazyVStack(spacing: 20) {
                        ForEach(vm.notes) { note in
                            NavigationLink(destination: EnhancedNoteDetailView(note: note)) {
                                EnhancedNoteCard(note: note)
                                    .padding(.horizontal, 24)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 32)
                }
                .padding(.top, 24)
            }
            .themedBackground(.primary)
            .navigationTitle("Zusammenfassungen")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: { /* Show unified recording */ }) {
                            Label("Neue Aufnahme", systemImage: "mic.fill")
                        }
                        Button(action: vm.newNote) {
                            Label("Neue Notiz", systemImage: "plus")
                        }
                        Button(action: { /* Show import hub */ }) {
                            Label("Import", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }

    private var searchArea: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("Semantische Suche & Volltext", text: $vm.query)
                    .onSubmit { vm.performSearch() }
                Button(action: vm.performSearch) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                }
            }
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.08), lineWidth: 1))
            .padding(.horizontal, 24)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(DashboardViewModel.Filter.allCases) { filter in
                        ChipView(title: filter.title, isSelected: vm.activeFilter == filter) {
                            vm.toggle(filter: filter)
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Quick Actions")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    QuickActionButton(title: "Neue Aufnahme", icon: "mic.circle.fill", action: vm.startRecording)
                    QuickActionButton(title: "URL einfügen", icon: "link.circle.fill", action: vm.showImportHub)
                    QuickActionButton(title: "PDF importieren", icon: "doc.circle.fill", action: vm.showImportHub)
                    QuickActionButton(title: "Bild scannen", icon: "viewfinder.circle.fill", action: vm.showScanner)
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private func sectionHeader(title: String) -> some View {
        HStack {
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
            Spacer()
        }
        .padding(.horizontal, 24)
    }
}

struct NoteCard: View {
    let note: Note
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(note.title).font(.title3).bold()
                Spacer()
                PipelineChip(state: note.pipeline)
            }
            Text(metaLine(note)).font(.footnote).foregroundStyle(.secondary)
            if !note.highlights.isEmpty {
                TagListView(tags: note.highlights)
            }
            if let md = note.summary?.markdown {
                Text(md.prefix(160))
                    .lineLimit(4)
            }
            HStack {
                NavigationLink(destination: NoteDetailView(note: note)) {
                    Label("Transkript", systemImage: "text.justifyleft")
                }
                Spacer()
                NavigationLink(destination: NoteDetailView(note: note, initialTab: .mindmap)) {
                    Label("Mindmap", systemImage: "tree")
                }
                Button(action: {}) {
                    Label("Teilen", systemImage: "square.and.arrow.up")
                }
            }
            .font(.callout)
        }.padding(16)
    }
    private func metaLine(_ n: Note) -> String {
        let d = DateFormatter.localizedString(from: n.createdAt, dateStyle: .medium, timeStyle: .short)
        let dur = n.duration.map { String(format: "%.0f min", $0/60) } ?? "–"
        return [d, n.location ?? "•", dur].joined(separator: "  ·  ")
    }
}

struct PipelineChip: View {
    let state: PipelineState
    var body: some View {
        HStack(spacing: 6) {
            ProgressView(value: state.progress)
                .frame(width: 44)
            Text(label(for: state.stage))
                .font(.caption2)
        }.padding(6)
         .background(.thinMaterial, in: Capsule())
    }
    private func label(for s: PipelineState.Stage) -> String {
        switch s {
        case .done: return "Fertig"
        case .transcribing: return "ASR"
        case .diarizing: return "Sprecher"
        case .summarizing: return "Summary"
        case .roleSummaries: return "Rollen"
        case .mindmap: return "Mindmap"
        case .indexing: return "Index"
        case .chunking: return "Chunks"
        case .error: return "Fehler"
        default: return "Wartet"
        }
    }
}
