//
//  MeetingsView.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import SwiftUI

struct MeetingsView: View {
    @EnvironmentObject var notesViewModel: NotesViewModel

    var body: some View {
        NavigationStack {
            NotesListView()
                .navigationTitle("Meeting-Protokolle")
        }
    }
}
