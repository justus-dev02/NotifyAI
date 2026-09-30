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
    /// (iOS), and prevents App Nap from throttling it (macOS).
    ///
    /// When iOS ends the extra time, `onExpiration` is called and the background task is
    /// ended right away, inside the expiration handler. The work is cancelled but may need a
    /// moment to wind down (WhisperKit and the language model do not stop mid-call); iOS
    /// terminates apps that keep an expired task open, so the task must not wait for it.
    static func run(named name: String, onExpiration: @escaping @MainActor () -> Void, _ work: () async -> Void) async {
        #if os(iOS)
        let task = BackgroundTask()
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated {
                onExpiration()
                task.expire()
            }
        }
        task.begin(identifier)
        await work()
        task.end()
        #else
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: name)
        await work()
        ProcessInfo.processInfo.endActivity(activity)
        #endif
    }
}

#if os(iOS)
/// A background task that is ended exactly once: either by the expiration handler or when
/// the work finishes, whichever comes first.
@MainActor
private final class BackgroundTask {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var hasExpired = false

    /// With no background time left, iOS may call the expiration handler before
    /// `beginBackgroundTask` returns; the task is then ended as soon as its identifier exists.
    func begin(_ identifier: UIBackgroundTaskIdentifier) {
        self.identifier = identifier
        if hasExpired {
            end()
        }
    }

    func expire() {
        hasExpired = true
        end()
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif
