//
//  PlatformServices.swift
//  NotifyAI
//

import AppIntents
import NotifyAIServices
import SwiftUI

/// What only one platform has, behind one type.
///
/// - iOS / iPadOS: the recording's Live Activity with its buttons, and background tasks
///   that let long processing continue when the user leaves the app.
/// - macOS: the monitor of running audio apps and output devices for the source pickers.
///
/// This is the only place of the app's composition that distinguishes platforms; the
/// composition root, the lifecycle and the services stay free of `#if os(…)`.
@MainActor
final class PlatformServices {
    #if os(iOS)
    private let liveActivity = RecordingLiveActivity()
    private var backgroundScheduler: BackgroundProcessingScheduler?
    #else
    let audioEnvironment = AudioEnvironmentMonitor()
    #endif

    /// Shows a running recording outside the app, where the platform can.
    var recordingActivity: (any RecordingActivityPresenting)? {
        #if os(iOS)
        liveActivity
        #else
        nil
        #endif
    }

    /// Connects the platform's entry points to the services.
    /// - Parameter registersBackgroundTasks: `false` in tests, which run without the task
    ///   identifiers of the app's Info.plist.
    func connect(to services: ServiceContainer, registersBackgroundTasks: Bool) {
        #if os(iOS)
        let performer = RecordingIntentPerformer(recording: services.recording)
        AppDependencyManager.shared.add(dependency: performer as any RecordingIntentPerforming)
        guard registersBackgroundTasks else { return }
        // The services are created while the app launches, which is when iOS requires
        // background task handlers to be registered.
        let scheduler = BackgroundProcessingScheduler(processing: services.processing)
        scheduler.registerOvernightTask()
        backgroundScheduler = scheduler
        #endif
    }

    /// The app moved to the background: unfinished work is scheduled for the night (iOS).
    func didEnterBackground() {
        #if os(iOS)
        backgroundScheduler?.scheduleOvernightProcessingIfNeeded()
        #endif
    }
}

extension View {
    /// Injects the objects only one platform has.
    func platformEnvironment(_ platform: PlatformServices) -> some View {
        #if os(macOS)
        environment(platform.audioEnvironment)
        #else
        self
        #endif
    }
}
