//
//  AppEnvironment.swift
//  NotifyAI
//

import Foundation
import NotifyAIPersistence
import NotifyAIServices
import SwiftUI

@MainActor
final class AppEnvironment {
    let services: ServiceContainer
    let platform: PlatformServices
    let navigation = AppNavigation()
    let notices: UserNotices
    let lifecycle: AppLifecycle

    init(settings: AppSettings = AppSettings(), locations: StorageLocations, inMemory: Bool = false) throws {
        platform = PlatformServices()
        services = try ServiceContainer(
            settings: settings,
            locations: locations,
            inMemory: inMemory,
            recordingActivity: platform.recordingActivity
        )
        notices = UserNotices(store: services.store, recording: services.recording, integrations: services.integrations)
        lifecycle = AppLifecycle(services: services, platform: platform)
        platform.connect(to: services, registersBackgroundTasks: !inMemory)
    }

    /// Launch argument used by the UI tests: isolated in-memory data, onboarding skipped.
    static let uiTestingArgument = "-ui-testing"
    /// Launch argument that adds sample notes with tasks for the UI tests (debug builds).
    static let uiTestingSampleDataArgument = "-ui-testing-sample-data"
    /// Launch argument that adds the English notes for the App Store screenshots (debug builds).
    static let screenshotSampleDataArgument = "-screenshot-sample-data"

    /// The production environment. Unit and UI tests get an isolated in-memory store and
    /// never touch the user's data.
    /// - Throws: When the database cannot be opened; `AppLaunch` then offers a recovery.
    static func makeDefault() throws -> AppEnvironment {
        let processInfo = ProcessInfo.processInfo
        let isRunningUnitTests = processInfo.environment["XCTestConfigurationFilePath"] != nil
        let isRunningUITests = processInfo.arguments.contains(uiTestingArgument)
        if isRunningUnitTests || isRunningUITests {
            let suiteName = "NotifyAI-Testing"
            let defaults = UserDefaults(suiteName: suiteName) ?? .standard
            defaults.removePersistentDomain(forName: suiteName)
            let settings = AppSettings(defaults: defaults)
            settings.general.hasCompletedOnboarding = isRunningUITests
            let environment = try AppEnvironment(settings: settings, locations: try StorageLocations.temporary(), inMemory: true)
            #if DEBUG
            if processInfo.arguments.contains(uiTestingSampleDataArgument) {
                try SampleData.insertUITestNotes(into: environment.services)
            }
            if processInfo.arguments.contains(screenshotSampleDataArgument) {
                try SampleData.insertScreenshotNotes(into: environment.services)
            }
            #endif
            return environment
        }
        return try AppEnvironment(locations: try StorageLocations.applicationSupport())
    }
}

extension View {
    /// Injects every object views may use. Each one is injected by its own type.
    func appEnvironment(_ app: AppEnvironment) -> some View {
        let services = app.services
        return self
            .environment(services.settings)
            .environment(services.processing)
            .environment(services.recording)
            .environment(services.whisperModels)
            .environment(services.neuralModels)
            .environment(services.speakers)
            .environment(services.transcriptEditor)
            .environment(services.templates)
            .environment(services.integrations)
            .environment(services.appLock)
            .environment(services.knowledge)
            .environment(services.tasks)
            .environment(services.library)
            .environment(services.labels)
            .environment(services.collections)
            .environment(services.importer)
            .environment(services.storage)
            .environment(services.audioSession)
            .environment(app.navigation)
            .environment(services.chat)
            .environment(app.notices)
            .environment(app.lifecycle)
            .platformEnvironment(app.platform)
            .modelContainer(services.store.container)
    }
}
