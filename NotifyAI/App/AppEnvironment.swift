//
//  AppEnvironment.swift
//  NotifyAI
//

import Foundation
import OSLog
import SwiftData
import SwiftUI

/// Composition root: creates every service once and wires the dependencies.
///
/// Views receive the objects they need through the SwiftUI environment. Nothing in the
/// app reaches for a global singleton, which keeps dependencies visible and testable.
@MainActor
final class AppEnvironment {
    let settings: AppSettings
    let navigation: AppNavigation
    let store: NoteStore
    let processing: ProcessingCoordinator
    let recording: RecordingController
    let whisperModels: WhisperModelManager
    let appLock: AppLock
    let audioSession: AudioSessionController
    let importer: ImportService
    private var hasStarted = false

    init(settings: AppSettings = AppSettings(), locations: StorageLocations, inMemory: Bool = false) throws {
        self.settings = settings
        navigation = AppNavigation()
        audioSession = AudioSessionController()
        store = try NoteStore(locations: locations, inMemory: inMemory)

        let modelStore = WhisperModelStore(downloadBase: locations.whisperModelsDirectory)
        let whisperEngine = WhisperEngine(modelStore: modelStore)
        let transcription = TranscriptionService(appleSpeech: AppleSpeechEngine(), whisper: whisperEngine)

        whisperModels = WhisperModelManager(store: modelStore) {
            await whisperEngine.unloadModel()
        }
        processing = ProcessingCoordinator(
            store: store,
            settings: settings,
            transcription: transcription,
            summarization: SummarizationService(),
            diarizer: SpeakerDiarizer()
        )
        recording = RecordingController(
            store: store,
            settings: settings,
            transcription: transcription,
            processing: processing,
            audioSession: audioSession
        )
        importer = ImportService(store: store, settings: settings, processing: processing)
        appLock = AppLock { [settings] in settings.appLockEnabled }

        applyBackupPreference()
    }

    /// Launch argument used by the UI tests: isolated in-memory data, onboarding skipped.
    static let uiTestingArgument = "-ui-testing"

    /// The production environment. Unit and UI tests get an isolated in-memory store and
    /// never touch the user's data.
    static func makeDefault() -> AppEnvironment {
        let processInfo = ProcessInfo.processInfo
        let isRunningUnitTests = processInfo.environment["XCTestConfigurationFilePath"] != nil
        let isRunningUITests = processInfo.arguments.contains(uiTestingArgument)
        do {
            if isRunningUnitTests || isRunningUITests {
                let suiteName = "NotifyAI-Testing"
                let defaults = UserDefaults(suiteName: suiteName) ?? .standard
                defaults.removePersistentDomain(forName: suiteName)
                let settings = AppSettings(defaults: defaults)
                settings.hasCompletedOnboarding = isRunningUITests
                return try AppEnvironment(settings: settings, locations: try StorageLocations.temporary(), inMemory: true)
            }
            return try AppEnvironment(locations: try StorageLocations.applicationSupport())
        } catch {
            // Without a store the app cannot do anything useful; fail loudly and early.
            Logger.persistence.fault("Creating the app environment failed: \(error.localizedDescription, privacy: .public)")
            fatalError("NotifyAI could not open its database: \(error)")
        }
    }

    func applyBackupPreference() {
        do {
            try store.locations.setIncludedInBackup(settings.includeInBackup)
        } catch {
            Logger.persistence.error("Updating the backup setting failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Called when the first window appears. Later calls (more windows) do nothing.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        processing.resumePendingWork()
        await whisperModels.refresh()
    }
}

extension View {
    /// Injects all shared objects of the environment.
    func appEnvironment(_ app: AppEnvironment) -> some View {
        self
            .environment(app.settings)
            .environment(app.navigation)
            .environment(app.processing)
            .environment(app.recording)
            .environment(app.whisperModels)
            .environment(app.appLock)
            .environment(\.appEnvironment, app)
            .modelContainer(app.store.container)
    }
}

extension EnvironmentValues {
    /// Access to services that are not observable themselves (store, audio session).
    @Entry var appEnvironment: AppEnvironment?
}
