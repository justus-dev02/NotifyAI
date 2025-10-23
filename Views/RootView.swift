//
//  RootView.swift
//  NotifyAI
//
//  Created by Justus on 23.10.25.
//

import SwiftUI

struct RootView: View {
    @StateObject private var appState = AppState()
    @StateObject private var dashboardViewModel = DashboardViewModel()
    @StateObject private var onboardingViewModel = OnboardingViewModel()
    @StateObject private var themeManager = ThemeManager()

    var body: some View {
        switch appState.currentView {
        case .onboarding:
            OnboardingFlowView(viewModel: onboardingViewModel)
                .environmentObject(appState)
                .environmentObject(themeManager)
        case .dashboard:
            MainTabView()
                .environmentObject(dashboardViewModel)
                .environmentObject(appState)
                .environmentObject(themeManager)
        }
    }
}
