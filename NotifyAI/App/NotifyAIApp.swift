//
//  NotifyAIApp.swift
//  NotifyAI
//

import NotifyAIServices
import SwiftUI

@main
struct NotifyAIApp: App {
    #if os(macOS)
    /// Owns the launch state and the updater, because AppKit's callbacks need them too.
    @NSApplicationDelegateAdaptor(NotifyAIAppDelegate.self) private var appDelegate
    private var launch: AppLaunch { appDelegate.launch }
    #else
    /// Creates the environment; when the database cannot be opened, the app shows a
    /// recovery screen instead of crashing.
    @State private var launch = AppLaunch()
    #endif

    var body: some Scene {
        mainWindow
        #if os(macOS)
        settingsWindow
        menuBarItem
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
    /// A single-instance window: `openWindow(id:)` brings the existing window to the front
    /// instead of creating another one (the menu bar opens it repeatedly).
    private var mainWindow: some Scene {
        Window("NotifyAI", id: SceneID.main) {
            rootContent
        }
        .defaultSize(width: 1_120, height: 740)
        .commands {
            AppCommands(launch: launch, updater: appDelegate.updater)
        }
    }

    private var settingsWindow: some Scene {
        Settings {
            if let app = launch.environment {
                SettingsView()
                    .appEnvironment(app)
                    .environment(appDelegate.updater)
                    .frame(width: 560, height: 640)
            } else {
                DatabaseRecoveryView(launch: launch)
                    .frame(width: 560, height: 480)
            }
        }
    }

    private var menuBarItem: some Scene {
        MenuBarExtra(isInserted: menuBarItemBinding) {
            if let app = launch.environment {
                MenuBarPanel()
                    .appEnvironment(app)
            }
        } label: {
            if let app = launch.environment {
                MenuBarLabel(recording: app.services.recording)
            } else {
                Image(systemName: "waveform")
            }
        }
        .menuBarExtraStyle(.window)
    }

    /// The menu bar item follows the "App anzeigen in" setting. If the user removes it by
    /// ⌘-dragging it out of the menu bar, the app switches to the Dock so it stays reachable.
    /// Without an environment (database recovery) the app lives in the Dock.
    private var menuBarItemBinding: Binding<Bool> {
        let settings = launch.environment?.services.settings
        return Binding {
            settings?.general.appPresence.showsMenuBarItem ?? false
        } set: { isInserted in
            guard let settings, !isInserted, settings.general.appPresence.showsMenuBarItem else { return }
            settings.general.appPresence = .dock
            AppPresenceController.apply(.dock)
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
