//
//  NotesListView.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import SwiftUI

struct NotesListView: View {
    @EnvironmentObject var notesVM: NotesViewModel

    var body: some View {
        NavigationStack {
            List {
                ForEach(notesVM.results) { note in
                    NavigationLink(note.title) { NoteDetailView(note: note) }
                }
            }
            .navigationTitle("AI Notes")
            .toolbar {
                Button { notesVM.createNew() } label: { Image(systemName: "plus") }
            }
            .searchable(text: $notesVM.query, prompt: "Semantisch suchen…")
            .onChange(of: notesVM.query) { _ in notesVM.performSearch() }
        }
    }
}

