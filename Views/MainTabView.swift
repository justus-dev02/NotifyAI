//
//  MainTabView.swift
//  NotifyAI
//
//  Created by OpenAI Assistant on 05.10.23.
//

import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Dashboard", systemImage: "square.grid.2x2")
                }

            NotesListView()
                .tabItem {
                    Label("Notizen", systemImage: "list.bullet.rectangle")
                }

            RecorderTabView()
                .tabItem {
                    Label("Recorder", systemImage: "mic.fill")
                }

            SettingsView()
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
