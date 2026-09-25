//
//  MainTabView.swift
//  NotifyAI
//
//  Created by OpenAI Assistant on 05.10.23.
//  Updated for Liquid Glass Design (Search integrated into Notes).
//

import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var notesViewModel = NotesViewModel()
    @StateObject private var settingsViewModel = SettingsViewModel()
    
    var body: some View {
        TabView {
            DashboardView()
                .environmentObject(notesViewModel)
                .environmentObject(settingsViewModel)
                .environmentObject(themeManager)
                .tabItem {
                    Label("Dashboard", systemImage: "sparkles.rectangle.stack.fill")
                }

            NotesListView()
                .environmentObject(notesViewModel)
                .environmentObject(settingsViewModel)
                .environmentObject(themeManager)
                .tabItem {
                    Label("Notizen", systemImage: "note.text")
                }

            SettingsView()
                .environmentObject(notesViewModel)
                .environmentObject(settingsViewModel)
                .environmentObject(themeManager)
                .tabItem {
                    Label("Einstellungen", systemImage: "gearshape.fill")
                }
        }
        .tint(AppTheme.accent)
        .preferredColorScheme(themeManager.isDarkMode ? .dark : .light)
    }
}

#Preview {
    MainTabView()
        .environmentObject(AppState())
        .environmentObject(ThemeManager())
}
