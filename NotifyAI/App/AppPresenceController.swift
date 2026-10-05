//
//  AppPresenceController.swift
//  NotifyAI
//

#if os(macOS)
import AppKit
import NotifyAIServices

/// Shows or hides the Dock icon according to `AppPresence`.
///
/// The Dock icon is controlled by the activation policy: `.regular` apps have a Dock icon
/// and an app menu, `.accessory` apps have neither and live in the menu bar only. The menu
/// bar item itself is inserted or removed by the `MenuBarExtra` scene.
@MainActor
enum AppPresenceController {
    static func apply(_ presence: AppPresence) {
        let policy: NSApplication.ActivationPolicy = presence.showsDockIcon ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Changing the policy deactivates the app; bring its windows back to the front,
        // otherwise the settings window the user is working in would disappear behind others.
        DispatchQueue.main.async {
            NSApp.activate()
        }
    }
}

/// Connects AppKit's application callbacks to the app.
///
/// AppKit creates the delegate itself, before the first scene. So the delegate owns what its
/// callbacks need, the app's launch state and the updater, and `NotifyAIApp` reads them from
/// it. No global state is needed to reach the app from these callbacks.
@MainActor
final class NotifyAIAppDelegate: NSObject, NSApplicationDelegate {
    let launch: AppLaunch
    /// Created with the app, independent of the database, so updates keep working even when
    /// the recovery screen is shown.
    let updater: AppUpdater

    override init() {
        let launch = AppLaunch()
        self.launch = launch
        updater = AppUpdater(deferral: launch)
        super.init()
    }

    /// Applies the presence before the first window appears, so a menu-bar-only app never
    /// flashes a Dock icon at launch. Without an environment (database recovery) the app
    /// shows its Dock icon and window, otherwise the recovery screen would be unreachable.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let presence = launch.environment == nil ? .dock : GeneralSettings.storedAppPresence()
        AppPresenceController.apply(presence)
    }

    /// Closing the main window keeps the app running: in the Dock like other Mac apps, or in
    /// the menu bar, where recordings can be started and continue.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Quitting during a recording finishes it first: the file is finalized, the live
    /// transcript saved and the note queued, exactly as if the user had pressed stop.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recording = launch.environment?.services.recording, recording.isActive, recording.phase != .finishing else {
            return .terminateNow
        }
        Task {
            await recording.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif
