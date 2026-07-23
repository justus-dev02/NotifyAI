//
//  NotesListView.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import SwiftUI

struct NotesListView: View {
    @EnvironmentObject var notesVM: NotesViewModel
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                ForEach(notesVM.results) { note in
                    NavigationLink(destination: EnhancedNoteDetailView(note: note)) {
                        noteRow(note)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            withAnimation {
                                notesVM.delete(note: note)
                            }
                        } label: {
                            Label("Löschen", systemImage: "trash.fill")
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            withAnimation {
                                notesVM.delete(note: note)
                            }
                        } label: {
                            Label("Löschen", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        let note = notesVM.results[index]
                        notesVM.delete(note: note)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        notesVM.createNew()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .fontWeight(.bold)
                                .foregroundStyle(Color.indigo)
                            Text("Neu")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.adaptiveLabel)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                    }
                }
            }
            .searchable(text: $notesVM.query, prompt: "Transkripte & Notizen durchsuchen…")
            .onChange(of: notesVM.query) { _ in
                notesVM.performSearch()
            }
        }
    }

    private func noteRow(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(note.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(formattedDate(note.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let summary = note.summary?.markdown, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if !note.segments.isEmpty {
                Text(note.segments.map { $0.text }.joined(separator: " "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if !note.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(note.tags.prefix(3), id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.indigo.opacity(0.1))
                            .foregroundStyle(Color.indigo)
                            .clipShape(Capsule())
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
