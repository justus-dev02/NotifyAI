//
//  ServiceContainer.swift
//  NotifyAIServices
//

import Foundation
import NotifyAIAudio
import NotifyAICore
import NotifyAIIntegrations
import NotifyAIKnowledge
import NotifyAILibrary
import NotifyAINeuralModels
import NotifyAIPersistence
import NotifyAIProcessing
import NotifyAIRecording
import NotifyAISettings
import NotifyAISpeakers
import NotifyAISummarization
import NotifyAISupport
import NotifyAITranscription

/// Creates every service once and wires their dependencies.
///
/// The services' initializers are `package`: the app cannot build a second
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
    public let neuralModels: NeuralModelManager
    public let speakers: SpeakerDirectory
    public let transcriptEditor: TranscriptEditor
    public let templates: SummaryTemplates
    public let integrations: IntegrationService
    public let appLock: AppLock
    public let audioSession: AudioSessionController
    public let importer: ImportService
    public let knowledge: KnowledgeIndexService
    public let chat: NoteChatModel
    public let tasks: TaskBoard
    public let library: NoteLibrary
    public let labels: NoteLabels
    public let collections: NoteCollections
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
        let neuralStore = NeuralModelStore(downloadBase: locations.neuralModelsDirectory)
        let parakeetEngine = ParakeetEngine(store: neuralStore)
        let speakerDetection = SpeakerDetection(neural: NeuralSpeakerDiarizer(store: neuralStore))
        let transcription = TranscriptionService(appleSpeech: AppleSpeechEngine(), whisper: whisperEngine, parakeet: parakeetEngine)
        whisperModels = WhisperModelManager(store: modelStore, usage: whisperEngine)
        neuralModels = NeuralModelManager(store: neuralStore, usages: [parakeetEngine, speakerDetection.neural])

        // Search and related notes use the contextual model. The summary's evidence links keep
        // the sentence embeddings their thresholds were measured with.
        let embedder = ContextualSentenceEmbedder(fallback: SentenceEmbedder())
        let summarization = SummarizationService()
        let digestStore = ChapterDigestStore(directory: inMemory ? nil : locations.processingDirectory)
        processing = ProcessingCoordinator(
            store: store,
            settings: settings,
            transcription: transcription,
            summarization: summarization,
            diarizer: speakerDetection,
            embedder: SentenceEmbedder(),
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
        speakers = SpeakerDirectory(store: store, detection: speakerDetection)
        transcriptEditor = TranscriptEditor(store: store)
        templates = SummaryTemplates(store: store, processing: processing, settings: settings.analysis)
        let integrationState = inMemory ? nil : locations.integrationStateURL
        integrations = IntegrationService(store: store, settings: settings.integrations, processing: processing, stateURL: integrationState)
        importer = ImportService(store: store, settings: settings, processing: processing)
        library = NoteLibrary(store: store, processing: processing)
        labels = NoteLabels(store: store)
        collections = NoteCollections(store: store, processing: processing)
        tasks = TaskBoard(store: store, library: library)
        storage = StorageMaintenance(locations: locations, settings: settings, library: library)
        appLock = AppLock(settings: settings.privacy)
        storage.applyBackupPreference()
    }

    /// Starts the work that runs without the user: interrupted processing continues, old
    /// recordings lose their audio as the user chose, the search index and the task board
    /// catch up. Called once, when the first window appears.
    public func start() async {
        processing.resumePendingWork()
        storage.applyAudioRetention()
        knowledge.scheduleRefresh()
        tasks.startObserving()
        await whisperModels.refresh()
        await neuralModels.refresh()
    }
}
