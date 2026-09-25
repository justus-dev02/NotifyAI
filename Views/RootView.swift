//
//  RootView.swift
//  NotifyAI
//
//  Created by Justus on 23.10.25.
//  Updated for Biometric Lock Protection & Flow Control.
//

import SwiftUI

struct RootView: View {
    @StateObject private var appState = AppState()
    @StateObject private var dashboardViewModel = DashboardViewModel()
    @StateObject private var onboardingViewModel = OnboardingViewModel()
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var settingsViewModel = SettingsViewModel()

    var body: some View {
        Group {
            if settingsViewModel.biometricLock && !settingsViewModel.isUnlocked {
                biometricLockScreen
            } else {
                switch appState.currentView {
                case .onboarding:
                    OnboardingFlowView(viewModel: onboardingViewModel)
                        .environmentObject(appState)
                        .environmentObject(themeManager)
                        .environmentObject(settingsViewModel)
                case .dashboard:
                    MainTabView()
                        .environmentObject(dashboardViewModel)
                        .environmentObject(appState)
                        .environmentObject(themeManager)
                        .environmentObject(settingsViewModel)
                }
            }
        }
        .onAppear {
            if settingsViewModel.biometricLock {
                settingsViewModel.authenticateUser()
            }
        }
    }

    private var biometricLockScreen: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "lock.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.indigo)

            VStack(spacing: 8) {
                Text("NotifyAI ist geschützt")
                    .font(.title2.bold())
                    .foregroundStyle(Color.adaptiveLabel)

                Text("Bitte entsperre die App mit Face ID oder Touch ID, um fortzufahren.")
                    .font(.subheadline)
                    .foregroundStyle(Color.adaptiveSecondaryLabel)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            if let error = settingsViewModel.authErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
            }

            Button {
                settingsViewModel.authenticateUser()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "faceid")
                        .font(.headline)
                    Text("Jetzt entsperren")
                        .font(.headline.bold())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(Color.indigo, in: Capsule())
                .shadow(color: Color.indigo.opacity(0.35), radius: 10, y: 4)
            }
            .padding(.top, 12)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .liquidGlassBackground()
    }
}
