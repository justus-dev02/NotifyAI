//
//  NotifyAIApp.swift
//  NotifyAI
//

import SwiftUI

@main
struct NotifyAIApp: App {
    /// Creates the environment; when the database cannot be opened, the app shows a
    /// recovery screen instead of crashing.
    @State private var launch: AppLaunch
    #if os(macOS)
    @NSApplicationDelegateAdaptor(NotifyAIAppDelegate.self) private var appDelegate
    /// Created with the app, independent of the database, so updates keep working even
    /// when the recovery screen is shown.
    @State private var updater: AppUpdater
    #endif

    init() {
        let launch = AppLaunch()
        _launch = State(initialValue: launch)
        #if os(macOS)
        NotifyAIAppDelegate.launch = launch
        _updater = State(initialValue: AppUpdater {
            launch.environment?.recording.isActive ?? false
        })
        #endif
    }

    var body: some Scene {
        mainWindow

        #if os(macOS)
        Settings {
            if let app = launch.environment {
                SettingsView()
                    .appEnvironment(app)
                    .environment(updater)
                    .frame(width: 560, height: 640)
            } else {
                DatabaseRecoveryView(launch: launch)
                    .frame(width: 560, height: 480)
            }
        }

        MenuBarExtra(isInserted: menuBarItemBinding) {
            if let app = launch.environment {
                MenuBarPanel()
                    .appEnvironment(app)
            }
        } label: {
            if let app = launch.environment {
                MenuBarLabel(recording: app.recording)
            } else {
                Image(systemName: "waveform")
            }
        }
        .menuBarExtraStyle(.window)
        #endif
    }

    @ViewBuilder
    private var rootContent: some View {
        if let app = launch.environment {
            RootView()
                .appEnvironment(app)
        } else {
            DatabaseRecoveryView(launch: launch)
        }
    }

    #if os(macOS)
    /// The menu bar item follows the "App anzeigen in" setting. If the user removes it by
    /// ⌘-dragging it out of the menu bar, the app switches to the Dock so it stays reachable.
    /// Without an environment (database recovery) the app lives in the Dock.
    private var menuBarItemBinding: Binding<Bool> {
        let settings = launch.environment?.settings
        return Binding {
            settings?.general.appPresence.showsMenuBarItem ?? false
        } set: { isInserted in
            guard let settings, !isInserted, settings.general.appPresence.showsMenuBarItem else { return }
            settings.general.appPresence = .dock
            AppPresenceController.apply(.dock)
        }
    }

    /// A single-instance window: `openWindow(id:)` brings the existing window to the front
    /// instead of creating another one (the menu bar opens it repeatedly).
    private var mainWindow: some Scene {
        Window("NotifyAI", id: SceneID.main) {
            rootContent
        }
        .defaultSize(width: 1_120, height: 740)
        .commands {
            AppCommands(launch: launch, updater: updater)
        }
    }
    #else
    private var mainWindow: some Scene {
        WindowGroup(id: SceneID.main) {
            rootContent
        }
    }
    #endif
}

enum SceneID {
    static let main = "main"
}
