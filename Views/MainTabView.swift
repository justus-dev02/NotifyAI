//
//  MainTabView.swift
//  NotifyAI
//
//  Created by OpenAI Assistant on 05.10.23.
//

import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var notesViewModel = NotesViewModel()
    @StateObject private var settingsViewModel = SettingsViewModel()
    
    var body: some View {
        TabView {
            DashboardView()
                .environmentObject(notesViewModel)
                .environmentObject(settingsViewModel)
                .tabItem {
                    Label("Dashboard", systemImage: "square.grid.2x2")
                }

            NotesListView()
                .environmentObject(notesViewModel)
                .environmentObject(settingsViewModel)
                .tabItem {
                    Label("Notizen", systemImage: "list.bullet.rectangle")
                }

            ImportHubView()
                .environmentObject(notesViewModel)
                .environmentObject(settingsViewModel)
                .tabItem {
                    Label("Import", systemImage: "square.and.arrow.down.on.square")
                }

            RecorderTabView()
                .environmentObject(notesViewModel)
                .environmentObject(settingsViewModel)
                .tabItem {
                    Label("Recorder", systemImage: "mic.fill")
                }

            SearchView()
                .environmentObject(notesViewModel)
                .environmentObject(settingsViewModel)
                .tabItem {
                    Label("Suche", systemImage: "magnifyingglass")
                }

            SettingsView()
                .environmentObject(notesViewModel)
                .environmentObject(settingsViewModel)
                .tabItem {
                    Label("Einstellungen", systemImage: "gearshape")
                }
        }
    }
}

#Preview {
    MainTabView()
        .environmentObject(DashboardViewModel())
        .environmentObject(NotesViewModel())
        .environmentObject(SettingsViewModel())
}
