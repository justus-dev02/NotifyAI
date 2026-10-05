//
//  AppLifecycle.swift
//  NotifyAI
//

import Foundation
import NotifyAIServices
import Observation

/// What happens when the app starts, becomes active or moves to the background.
///
/// Views report the scene phase here instead of reaching for the services themselves.
@MainActor
@Observable
final class AppLifecycle {
    @ObservationIgnored private let services: ServiceContainer
    @ObservationIgnored private let platform: PlatformServices
    @ObservationIgnored private var hasStarted = false

    init(services: ServiceContainer, platform: PlatformServices) {
        self.services = services
        self.platform = platform
    }

    /// Called when the first window or the menu bar panel appears. Later calls do nothing.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await services.start()
    }

    /// Work stopped when background time ended continues from its last saved step.
    func didBecomeActive() {
        services.processing.resumeQueuedWork()
    }

    func didEnterBackground() {
        platform.didEnterBackground()
    }
}
