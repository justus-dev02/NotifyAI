//
//  NotifyAIApp.swift
//  NotifyAI
//
//  Created by Justus on 08.09.25.
//

/*import SwiftUI

@main
struct NotifyAIApp: App {
    @StateObject private var serviceLocator = ServiceLocator.shared
    @StateObject private var dashboardVM = DashboardViewModel()
    @StateObject private var notesVM = NotesViewModel()
    @StateObject private var settingsVM = SettingsViewModel()

    @StateObject private var onboardingVM = OnboardingViewModel()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    MainTabView()
                } else {
                    OnboardingFlowView(viewModel: onboardingVM)
                }
            }
            .environmentObject(serviceLocator)
            .environmentObject(dashboardVM)
            .environmentObject(notesVM)
            .environmentObject(settingsVM)
        }
    }
}
*/

import SwiftUI

@main
struct NotifyAIApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

