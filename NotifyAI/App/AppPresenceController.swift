//
//  AppPresenceController.swift
//  NotifyAI
//

#if os(macOS)
import AppKit

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
/// `launch` is handed over once in `NotifyAIApp.init`, because AppKit creates the delegate
/// itself; it is the only way into the app for these callbacks.
@MainActor
final class NotifyAIAppDelegate: NSObject, NSApplicationDelegate {
    static var launch: AppLaunch?

    /// Applies the presence before the first window appears, so a menu-bar-only app never
    /// flashes a Dock icon at launch. Without an environment (database recovery) the app
    /// shows its Dock icon and window, otherwise the recovery screen would be unreachable.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let presence = Self.launch?.environment == nil ? .dock : GeneralSettings.storedAppPresence()
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
        guard let recording = Self.launch?.environment?.recording, recording.isActive, recording.phase != .finishing else {
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
