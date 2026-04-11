//
//  MainTabView.swift
//  NotifyAI
//
//  Created by OpenAI Assistant on 05.10.23.
//

import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var notesViewModel = NotesViewModel()
    @StateObject private var settingsViewModel = SettingsViewModel()
    @StateObject private var templateLibrary = TemplateLibrary()
    @StateObject private var learningGenerator = LearningGenerator()
    
    var body: some View {
        TabView {
            DashboardView()
                .environmentObject(notesViewModel)
                .environmentObject(settingsViewModel)
                .environmentObject(themeManager)
                .tabItem {
                    Label("Dashboard", systemImage: "square.grid.2x2")
                }

            NotesListView()
                .environmentObject(notesViewModel)
                .environmentObject(settingsViewModel)
                .environmentObject(themeManager)
                .tabItem {
                    Label("Notizen", systemImage: "list.bullet.rectangle")
                }

            SearchView()
                .environmentObject(notesViewModel)
                .environmentObject(settingsViewModel)
                .environmentObject(themeManager)
                .tabItem {
                    Label("Suche", systemImage: "magnifyingglass")
                }

            /*TranscriptionView()
                .environmentObject(themeManager)
                .tabItem {
                    Label("Transkription", systemImage: "waveform")
                }*/

            SettingsView()
                .environmentObject(notesViewModel)
                .environmentObject(settingsViewModel)
                .environmentObject(themeManager)
                .tabItem {
                    Label("Einstellungen", systemImage: "gearshape")
                }
        }
        .accentColor(AppTheme.accent)
        .preferredColorScheme(themeManager.isDarkMode ? .dark : .light)
    }
}

#Preview {
    MainTabView()
        .environmentObject(DashboardViewModel())
        .environmentObject(NotesViewModel())
        .environmentObject(SettingsViewModel())
}
