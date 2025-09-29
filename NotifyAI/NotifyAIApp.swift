//
//  NotifyAIApp.swift
//  NotifyAI
//
//  Created by Justus on 08.09.25.
//

import SwiftUI

@main
struct NotifyAIApp: App {
    @StateObject private var serviceLocator = ServiceLocator.shared
    @StateObject private var dashboardVM = DashboardViewModel()
    @StateObject private var notesVM = NotesViewModel()
    @StateObject private var settingsVM = SettingsViewModel()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(serviceLocator)
                .environmentObject(dashboardVM)
                .environmentObject(notesVM)
                .environmentObject(settingsVM)
        }
    }
}
