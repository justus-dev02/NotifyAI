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
    let knowledge: KnowledgeIndexService
    let chat: NoteChatModel
    let notices: UserNotices
    let tasks: TaskBoard
    #if os(iOS)
    let backgroundScheduler: BackgroundProcessingScheduler
    #else
    let audioEnvironment: AudioEnvironmentMonitor
    #endif
    private var hasStarted = false

    init(settings: AppSettings = AppSettings(), locations: StorageLocations, inMemory: Bool = false) throws {
        self.settings = settings
        navigation = AppNavigation()
        notices = UserNotices()
        audioSession = AudioSessionController()
        store = try NoteStore(locations: locations, inMemory: inMemory)
        store.onFailure = { [notices] message in
            notices.post(UserNotice(title: String(localized: "Nicht gespeichert"), message: message))
        }
        tasks = TaskBoard(store: store)
        #if os(macOS)
        audioEnvironment = AudioEnvironmentMonitor()
        #endif

        let modelStore = WhisperModelStore(downloadBase: locations.whisperModelsDirectory)
        let whisperEngine = WhisperEngine(modelStore: modelStore)
        let transcription = TranscriptionService(appleSpeech: AppleSpeechEngine(), whisper: whisperEngine)

        whisperModels = WhisperModelManager(store: modelStore) {
            await whisperEngine.isInUse
        } onModelRemoved: {
            await whisperEngine.unloadModel()
        }
        let embedder = SentenceEmbedder()
        let summarization = SummarizationService()
        let digestStore = ChapterDigestStore(directory: inMemory ? nil : locations.processingDirectory)
        processing = ProcessingCoordinator(
            store: store,
            settings: settings,
            transcription: transcription,
            summarization: summarization,
            diarizer: SpeakerDiarizer(),
            embedder: embedder,
            digestStore: digestStore
        )
        knowledge = KnowledgeIndexService(
            store: store,
            embedder: embedder,
            persistence: inMemory ? nil : KnowledgeIndexStore(
                directory: locations.knowledgeIndexDirectory,
                legacyFile: locations.legacyKnowledgeIndexURL
            )
        )
        chat = NoteChatModel(knowledge: knowledge, settings: settings)
        #if os(iOS)
        backgroundScheduler = BackgroundProcessingScheduler(processing: processing)
        #endif
        recording = RecordingController(
            store: store,
            settings: settings,
            transcription: transcription,
            processing: processing,
            audioSession: audioSession,
            notices: notices,
            liveChapters: LiveChapterSummarizer(summarization: summarization, store: digestStore)
        )
        importer = ImportService(store: store, settings: settings, processing: processing)
        appLock = AppLock { [settings] in settings.privacy.appLockEnabled }

        applyBackupPreference()
        connectLiveActivityIntents()
        connectSearchIndex()
        connectBackgroundProcessing(isTesting: inMemory)
    }

    /// Long recordings keep processing when the user leaves the app (iOS / iPadOS).
    private func connectBackgroundProcessing(isTesting: Bool) {
        #if os(iOS)
        // Tests run without registered task identifiers.
        guard !isTesting else { return }
        // The environment is created while the app launches, which is when iOS requires
        // background task handlers to be registered.
        backgroundScheduler.registerOvernightTask()
        processing.onJobStarted = { [backgroundScheduler] noteID, duration in
            backgroundScheduler.jobStarted(noteID: noteID, duration: duration)
        }
        #endif
    }

    /// Called when the app becomes active. Processing that iOS interrupted when the
    /// background time ended continues from its last saved step.
    func didBecomeActive() {
        processing.resumeQueuedWork()
    }

    /// Called when the app moves to the background.
    func didEnterBackground() {
        #if os(iOS)
        backgroundScheduler.scheduleOvernightProcessingIfNeeded()
        #endif
    }

    /// Keeps the search index in sync with finished and deleted notes.
    private func connectSearchIndex() {
        processing.onNoteReady = { [knowledge] _ in
            knowledge.scheduleRefresh()
        }
        store.onNotesDeleted = { [knowledge, processing] ids in
            knowledge.remove(ids)
            let digestStore = processing.digestStore
            Task {
                for id in ids {
                    await digestStore.remove(noteID: id)
                }
            }
        }
    }

    /// Launch argument used by the UI tests: isolated in-memory data, onboarding skipped.
    static let uiTestingArgument = "-ui-testing"

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
            if processInfo.arguments.contains(UITestSampleData.argument) {
                try UITestSampleData.insert(into: environment.store)
            }
            #endif
            return environment
        }
        return try AppEnvironment(locations: try StorageLocations.applicationSupport())
    }

    func applyBackupPreference() {
        do {
            try store.locations.setIncludedInBackup(settings.privacy.includeInBackup)
        } catch {
            Logger.persistence.error("Updating the backup setting failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Lets the buttons of the recording's Live Activity control the recording.
    private func connectLiveActivityIntents() {
        #if os(iOS)
        RecordingIntentHandler.handler = { [recording] action in
            switch action {
            case .togglePause:
                await recording.togglePause()
            case .stop:
                await recording.stop()
            }
        }
        #endif
    }

    /// Called when the first window appears. Later calls (more windows) do nothing.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        processing.resumePendingWork()
        knowledge.scheduleRefresh()
        tasks.startObserving()
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
            .environment(app.knowledge)
            .environment(app.chat)
            .environment(app.notices)
            .environment(app.tasks)
            #if os(macOS)
            .environment(app.audioEnvironment)
            #endif
            .environment(\.appEnvironment, app)
            .modelContainer(app.store.container)
    }
}

extension EnvironmentValues {
    /// Access to services that are not observable themselves (store, audio session).
    @Entry var appEnvironment: AppEnvironment?
}
