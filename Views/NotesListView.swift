//
//  NotesListView.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//  Updated with Apple Liquid Glass Design & Integrated Search.
//

import SwiftUI

struct NotesListView: View {
    @EnvironmentObject var notesVM: NotesViewModel
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager
    
    @State private var selectedFilter: NoteFilter = .all
    
    enum NoteFilter: String, CaseIterable, Identifiable {
        case all = "Alle"
        case audio = "Mit Audio"
        case actions = "Mit Aufgaben"
        
        var id: String { rawValue }
    }

    var filteredNotes: [Note] {
        let base = notesVM.results
        switch selectedFilter {
        case .all:
            return base
        case .audio:
            return base.filter { $0.audioURL != nil }
        case .actions:
            return base.filter { !($0.summary?.actionItems.isEmpty ?? true) }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Top Liquid Glass Search & Filter Bar
                VStack(spacing: 12) {
                    searchBar
                    filterChipsBar
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)

                // Notes List
                ScrollView(showsIndicators: false) {
                    if filteredNotes.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(spacing: 14) {
                            ForEach(filteredNotes) { note in
                                NavigationLink(destination: EnhancedNoteDetailView(note: note)) {
                                    EnhancedNoteCard(note: note)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        withAnimation {
                                            notesVM.delete(note: note)
                                        }
                                    } label: {
                                        Label("Löschen", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                        .padding(.bottom, 40)
                    }
                }
            }
            .liquidGlassBackground()
            .navigationTitle("Notizen")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        notesVM.createNew()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .bold))
                            Text("Neu")
                                .font(.subheadline.bold())
                        }
                        .foregroundStyle(Color.indigo)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                    }
                }
            }
        }
    }

    // MARK: - Liquid Glass Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.indigo)
                .font(.subheadline.bold())

            TextField("Transkripte & Notizen suchen…", text: $notesVM.query)
                .font(.subheadline)
                .onChange(of: notesVM.query) { _ in
                    notesVM.performSearch()
                }

            if !notesVM.query.isEmpty {
                Button {
                    notesVM.query = ""
                    notesVM.performSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.adaptiveSecondaryLabel)
                        .font(.caption)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: Color.indigo.opacity(0.04), radius: 8, y: 3)
    }

    // MARK: - Filter Chips Bar

    private var filterChipsBar: some View {
        HStack(spacing: 8) {
            ForEach(NoteFilter.allCases) { filter in
                filterButton(for: filter)
            }
            Spacer()
        }
    }

    private func filterButton(for filter: NoteFilter) -> some View {
        let isSelected = selectedFilter == filter
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedFilter = filter
            }
        } label: {
            Text(filter.rawValue)
                .font(.caption.bold())
                .foregroundStyle(isSelected ? Color.white : Color.adaptiveLabel)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(isSelected ? Color.indigo : Color.clear, in: Capsule())
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected ? Color.indigo : Color.white.opacity(0.2), lineWidth: 1)
                )
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.indigo.opacity(0.6))
                .padding(.top, 40)

            Text("Keine Notizen gefunden")
                .font(.headline)
                .foregroundStyle(Color.adaptiveLabel)

            Text(notesVM.query.isEmpty
                 ? "Erstelle eine neue Notiz oder starte eine Aufnahme."
                 : "Keine Treffer für \"\(notesVM.query)\".")
                .font(.caption)
                .foregroundStyle(Color.adaptiveSecondaryLabel)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

#Preview {
    NotesListView()
        .environmentObject(NotesViewModel())
        .environmentObject(AppState())
        .environmentObject(ThemeManager())
}
