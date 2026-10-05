//
//  RootView.swift
//  NotifyAI
//

import NotifyAIServices
import SwiftUI

/// Chooses between onboarding and the main interface and applies the app lock.
struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppLock.self) private var appLock
    @Environment(AppNavigation.self) private var navigation
    @Environment(RecordingController.self) private var recording
    @Environment(AppLifecycle.self) private var lifecycle
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if settings.general.hasCompletedOnboarding {
                MainView()
            } else {
                OnboardingView()
            }
        }
        .overlay {
            if appLock.isLocked {
                LockView()
                    .transition(.opacity)
            }
        }
        .animation(.default, value: appLock.isLocked)
        // While the recorder covers the window (iOS), it presents the notices itself.
        .userNoticeAlert(isActive: !navigation.isRecorderPresented && !appLock.isLocked)
        .task {
            await lifecycle.start()
            if appLock.isLocked {
                await appLock.unlock()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                appLock.lockIfEnabled()
                lifecycle.didEnterBackground()
            case .active:
                // Work stopped when background time ended continues now.
                lifecycle.didBecomeActive()
                if appLock.isLocked {
                    Task { await appLock.unlock() }
                }
            default:
                break
            }
        }
        .onOpenURL { url in
            // Tapping the recording's Live Activity opens `notifyai://recording`.
            if url.host() == "recording", recording.isActive {
                navigation.isRecorderPresented = true
            }
        }
    }
}
