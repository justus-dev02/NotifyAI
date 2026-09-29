//
//  NotifyAIApp.swift
//  NotifyAI
//

import SwiftUI

@main
struct NotifyAIApp: App {
    @State private var app = AppEnvironment.makeDefault()

    var body: some Scene {
        mainWindow

        #if os(macOS)
        Settings {
            SettingsView()
                .appEnvironment(app)
                .frame(width: 560, height: 640)
        }

        MenuBarExtra {
            MenuBarPanel()
                .appEnvironment(app)
        } label: {
            MenuBarLabel(recording: app.recording)
        }
        .menuBarExtraStyle(.window)
        #endif
    }

    #if os(macOS)
    /// A single-instance window: `openWindow(id:)` brings the existing window to the front
    /// instead of creating another one (the menu bar opens it repeatedly).
    private var mainWindow: some Scene {
        Window("NotifyAI", id: SceneID.main) {
            RootView()
                .appEnvironment(app)
        }
        .defaultSize(width: 1_120, height: 740)
        .commands {
            AppCommands(navigation: app.navigation, recording: app.recording)
        }
    }
    #else
    private var mainWindow: some Scene {
        WindowGroup(id: SceneID.main) {
            RootView()
                .appEnvironment(app)
        }
    }
    #endif
}

enum SceneID {
    static let main = "main"
}
