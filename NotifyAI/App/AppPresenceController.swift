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

/// Applies the presence before the first window appears, so a menu-bar-only app never
/// flashes a Dock icon at launch.
final class NotifyAIAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppPresenceController.apply(GeneralSettings.storedAppPresence())
        }
    }

    /// Closing the main window keeps the app running: in the Dock like other Mac apps, or in
    /// the menu bar, where recordings can be started and continue.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
#endif
