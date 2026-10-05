//
//  ServiceContainer.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore
import NotifyAIPersistence

/// Creates every service once and wires their dependencies.
///
/// The services' initializers are internal to this module: the app cannot build a second
/// store or a processing queue next to the real one, it receives exactly this graph. What
/// only the app can provide (presenting a recording outside the app needs ActivityKit and the
/// widget's attributes) is passed in as a protocol.
///
/// Services find out about each other's changes through events (`NoteStore.events`,
/// `ProcessingCoordinator.events`, …), not through callbacks set here, so each service shows
/// in its own initializer what it listens to.
@MainActor
public final class ServiceContainer {
    public let settings: AppSettings
    public let store: NoteStore
    public let processing: ProcessingCoordinator
    public let recording: RecordingController
    public let whisperModels: WhisperModelManager
    public let appLock: AppLock
    public let audioSession: AudioSessionController
    public let importer: ImportService
    public let knowledge: KnowledgeIndexService
    public let chat: NoteChatModel
    public let tasks: TaskBoard
    public let library: NoteLibrary
    public let storage: StorageMaintenance

    /// - Parameters:
    ///   - inMemory: Keeps notes, chapter digests and the search index in memory (tests).
    ///   - recordingActivity: Shows a running recording outside the app; `nil` where the
    ///     platform has no such presentation.
    public init(
        settings: AppSettings,
        locations: StorageLocations,
        inMemory: Bool = false,
        recordingActivity: (any RecordingActivityPresenting)?
    ) throws {
        self.settings = settings
        store = try NoteStore(locations: locations, inMemory: inMemory)
        audioSession = AudioSessionController()

        let modelStore = WhisperModelStore(downloadBase: locations.whisperModelsDirectory)
        let whisperEngine = WhisperEngine(modelStore: modelStore)
        let transcription = TranscriptionService(appleSpeech: AppleSpeechEngine(), whisper: whisperEngine)
        whisperModels = WhisperModelManager(store: modelStore, usage: whisperEngine)

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
        recording = RecordingController(
            store: store,
            settings: settings,
            transcription: transcription,
            processing: processing,
            audioSession: audioSession,
            devices: RecordingController.Devices(
                recorder: AudioRecorder(),
                microphone: SystemMicrophoneAccess(),
                system: SystemActivity(),
                activity: recordingActivity
            ),
            liveChapters: LiveChapterSummarizer(summarization: summarization, store: digestStore)
        )
        importer = ImportService(store: store, settings: settings, processing: processing)
        library = NoteLibrary(store: store, processing: processing)
        tasks = TaskBoard(store: store, library: library)
        storage = StorageMaintenance(locations: locations, settings: settings)
        appLock = AppLock(settings: settings.privacy)
        storage.applyBackupPreference()
    }

    /// Starts the work that runs without the user: interrupted processing continues, the
    /// search index and the task board catch up. Called once, when the first window appears.
    public func start() async {
        processing.resumePendingWork()
        knowledge.scheduleRefresh()
        tasks.startObserving()
        await whisperModels.refresh()
    }
}
