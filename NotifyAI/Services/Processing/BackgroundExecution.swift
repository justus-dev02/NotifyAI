//
//  BackgroundExecution.swift
//  NotifyAI
//

import Foundation
#if os(iOS)
import UIKit
#endif

/// Keeps work running briefly after the user leaves the app.
@MainActor
enum BackgroundExecution {
    /// Asks the system for extra time so the work can finish after the user leaves the app
    /// (iOS), and prevents App Nap from throttling it (macOS). `onExpiration` is called when
    /// iOS ends the extra time; the work must then stop soon.
    static func run(named name: String, onExpiration: @escaping @MainActor () -> Void, _ work: () async -> Void) async {
        #if os(iOS)
        let task = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { onExpiration() }
        }
        await work()
        UIApplication.shared.endBackgroundTask(task)
        #else
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: name)
        await work()
        ProcessInfo.processInfo.endActivity(activity)
        #endif
    }
}
