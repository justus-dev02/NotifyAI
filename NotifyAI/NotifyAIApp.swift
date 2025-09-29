//
//  NotifyAIApp.swift
//  NotifyAI
//
//  Created by Justus on 08.09.25.
//

import SwiftUI

@main
struct NotifyAIApp: App {
    @StateObject private var notesVM = NotesViewModel()

    var body: some Scene {
        WindowGroup {
            NotesListView()
                .environmentObject(notesVM)
                .environmentObject(ServiceLocator.shared)
        }
    }
}
