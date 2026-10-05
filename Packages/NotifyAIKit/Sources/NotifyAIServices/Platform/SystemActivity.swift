//
//  SystemActivity.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore
#if os(macOS)
import AppKit
#endif

/// The system side of a recording: App Nap, idle sleep and sleep notifications.
///
/// On the Mac, App Nap would throttle the capture and idle sleep would stop it; both are
/// suspended while recording. Closing the lid still puts the Mac to sleep, which is reported
/// through `willSleep`. iOS keeps a recording app running through its audio background mode,
/// so there is nothing to do there.
@MainActor
public final class SystemActivity: SystemActivityControlling {
    public let willSleep = EventChannel<Void>()
    #if os(macOS)
    private var activity: (any NSObjectProtocol)?
    private var sleepObserver: (any NSObjectProtocol)?
    #endif

    public init() {
        #if os(macOS)
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.willSleep.send(())
            }
        }
        #endif
    }

    isolated deinit {
        #if os(macOS)
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
        endRecordingActivity()
        #endif
    }

    public func beginRecordingActivity() {
        #if os(macOS)
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Recording"
        )
        #endif
    }

    public func endRecordingActivity() {
        #if os(macOS)
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
        #endif
    }
}
