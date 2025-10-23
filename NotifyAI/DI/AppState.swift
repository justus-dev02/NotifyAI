//
//  AppState.swift
//  NotifyAI
//
//  Created by Justus on 23.10.25.
//

import SwiftUI

class AppState: ObservableObject {
    @Published var currentView: AppView = .onboarding
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false

    enum AppView {
        case onboarding
        case dashboard
    }
    
    init() {
        // Check if onboarding has been completed
        if hasCompletedOnboarding {
            currentView = .dashboard
        } else {
            currentView = .onboarding
        }
    }
    
    func completeOnboarding() {
        hasCompletedOnboarding = true
        currentView = .dashboard
    }
}
