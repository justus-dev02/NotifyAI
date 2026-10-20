// swift-tools-version: 6.2
//
// Everything of NotifyAI below the user interface. The compiler enforces the direction of
// the dependencies; nothing here can reach back into the app, and no module can reach a
// module above it (ArchitectureTests checks the imports against the same table):
//
//   App (scenes, views, platform adapters)
//    ├─ DesignSystem
//    └─ NotifyAIServices ─ the composition root: builds and wires every service
//         ├─ NotifyAILibrary ─────── use cases of the screens: notes, labels, tasks,
//         │                          collections, templates, speakers, import, app lock
//         ├─ NotifyAIRecording ───── recording, live transcript, live chapters
//         ├─ NotifyAIIntegrations ── Obsidian, Notion, webhooks
//         ├─ NotifyAIKnowledge ───── search index, "Notizen fragen", related notes
//         ├─ NotifyAIExport ──────── Markdown, PDF, Word, subtitles
//         └─ NotifyAIProcessing ──── the queue: transcription → cleanup → speakers → summary
//              ├─ NotifyAISettings ─────── user preferences
//              ├─ NotifyAISummarization ── Apple Intelligence, extractive, chapters, tasks
//              ├─ NotifyAISpeakers ─────── speaker detection, voices, attribution
//              ├─ NotifyAITranscription ── Apple Speech, Whisper, Parakeet
//              │    └─ NotifyAINeuralModels ─ downloads of the Core ML models
//              └─ NotifyAIAudio ────────── recorder, player, session, devices, files
//                   └─ NotifyAISupport ─── text analysis, embeddings, platform, labels
//                        ├─ NotifyAIPersistence ─┐
//                        ├─ AudioCapture ────────┤
//                        └───────────────────────┴─ NotifyAICore
//
// Access control carries the second rule: models and the store are readable from the app,
// but every write is `package`, so only the services change notes. Between the service
// modules, `package` marks what one module offers the others; everything else stays internal.

import PackageDescription

/// A service module: its sources and string catalog live in `Sources/<name>`.
func service(_ name: String, _ dependencies: [Target.Dependency], strings: Bool = true) -> Target {
    .target(name: name, dependencies: dependencies, resources: strings ? [.process("Resources")] : [])
}

let whisperKit = Target.Dependency.product(name: "WhisperKit", package: "WhisperKit")
let fluidAudio = Target.Dependency.product(name: "FluidAudio", package: "FluidAudio")

let package = Package(
    name: "NotifyAIKit",
    defaultLocalization: "de",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "NotifyAICore", targets: ["NotifyAICore"]),
        .library(name: "AudioCapture", targets: ["AudioCapture"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "NotifyAIPersistence", targets: ["NotifyAIPersistence"]),
        .library(name: "NotifyAIServices", targets: ["NotifyAIServices"]),
    ],
    dependencies: [
        // Pinned to the revision the app has always used.
        .package(url: "https://github.com/argmaxinc/WhisperKit", revision: "f31370fbb39818e32722426eb9878665dfcfae3c"),
        // Speaker diarization and Parakeet on the Neural Engine. Without the default trait,
        // which links a text-normalization engine for speech synthesis the app does not use.
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.7", traits: []),
    ],
    targets: [
        /// Value types and rules: transcripts, markers, summaries, labels, due dates, audio
        /// format, logging and the event channel. Foundation and AVFoundation only.
        .target(name: "NotifyAICore"),
        /// Lock-free rings for the audio threads and the processing queue that converts,
        /// mixes, encodes and writes. No UI, no persistence.
        .target(name: "AudioCapture", dependencies: ["NotifyAICore"]),
        /// Theme and reusable SwiftUI components.
        .target(name: "DesignSystem", dependencies: ["NotifyAICore"]),
        /// The SwiftData schema with its migrations, the store and the file layout.
        .target(name: "NotifyAIPersistence", dependencies: ["NotifyAICore"]),

        // MARK: Services, bottom to top. None of them uses SwiftUI.

        /// What every service needs: text analysis and sentence embeddings, device load,
        /// platform adapters, display names, speaker labels, the keychain.
        service("NotifyAISupport", ["NotifyAICore", "NotifyAIPersistence"]),
        /// Recorder, player, audio session, devices, permissions, system audio, audio files.
        service("NotifyAIAudio", ["NotifyAICore", "NotifyAIPersistence", "AudioCapture", "NotifyAISupport"]),
        /// Downloading, verifying and deleting the Core ML models of Parakeet and speaker detection.
        service("NotifyAINeuralModels", ["NotifyAICore", "NotifyAIPersistence", "NotifyAISupport", fluidAudio]),
        /// Speech recognition with Apple Speech, Whisper and Parakeet, live and from files.
        service("NotifyAITranscription", [
            "NotifyAICore", "NotifyAIPersistence", "NotifyAISupport", "NotifyAIAudio", "NotifyAINeuralModels", whisperKit, fluidAudio,
        ]),
        /// Who speaks when: neural and spectral detection, voice profiles, attribution.
        service(
            "NotifyAISpeakers",
            ["NotifyAICore", "NotifyAIPersistence", "NotifyAISupport", "NotifyAIAudio", "NotifyAINeuralModels", fluidAudio],
            strings: false
        ),
        /// Summaries: Apple Intelligence, the extractive fallback, chapters, tasks, grounding.
        service("NotifyAISummarization", ["NotifyAICore", "NotifyAIPersistence", "NotifyAISupport"]),
        /// The user's preferences, one observable group per topic.
        service("NotifyAISettings", ["NotifyAICore", "NotifyAISupport", "NotifyAIAudio", "NotifyAITranscription"]),
        /// The processing queue and its pipeline.
        service("NotifyAIProcessing", [
            "NotifyAICore", "NotifyAIPersistence", "NotifyAISupport", "NotifyAITranscription",
            "NotifyAISpeakers", "NotifyAISummarization", "NotifyAISettings",
        ]),
        /// Markdown, PDF, Word and subtitle files.
        service("NotifyAIExport", ["NotifyAICore", "NotifyAIPersistence", "NotifyAISupport", "NotifyAISummarization"]),
        /// The search index, "Notizen fragen" and related notes.
        service("NotifyAIKnowledge", ["NotifyAICore", "NotifyAIPersistence", "NotifyAISupport", "NotifyAISummarization", "NotifyAISettings"]),
        /// Obsidian, Notion and webhooks.
        service("NotifyAIIntegrations", [
            "NotifyAICore", "NotifyAIPersistence", "NotifyAISupport", "NotifyAIExport", "NotifyAIProcessing", "NotifyAISettings",
        ]),
        /// Recording with live transcript and live chapters.
        service("NotifyAIRecording", [
            "NotifyAICore", "NotifyAIPersistence", "AudioCapture", "NotifyAISupport", "NotifyAIAudio", "NotifyAITranscription",
            "NotifyAISummarization", "NotifyAISettings", "NotifyAIProcessing",
        ]),
        /// The use cases of the screens: changing notes, labels, tasks, collections, templates,
        /// speakers, transcript corrections, import, storage, diagnostics, app lock.
        service("NotifyAILibrary", [
            "NotifyAICore", "NotifyAIPersistence", "NotifyAISupport", "NotifyAIAudio", "NotifyAITranscription",
            "NotifyAISpeakers", "NotifyAISummarization", "NotifyAISettings", "NotifyAIProcessing", "NotifyAIKnowledge",
        ]),
        /// The composition root: creates every service once and wires them. Re-exports the
        /// service modules, so the app imports one module.
        service("NotifyAIServices", [
            "NotifyAICore", "NotifyAIPersistence", "NotifyAISupport", "NotifyAIAudio", "NotifyAINeuralModels",
            "NotifyAITranscription", "NotifyAISpeakers", "NotifyAISummarization", "NotifyAISettings", "NotifyAIProcessing",
            "NotifyAIExport", "NotifyAIKnowledge", "NotifyAIIntegrations", "NotifyAIRecording", "NotifyAILibrary",
        ], strings: false),

        .testTarget(name: "NotifyAICoreTests", dependencies: ["NotifyAICore"]),
        .testTarget(name: "AudioCaptureTests", dependencies: ["AudioCapture", "NotifyAICore"]),
        /// The dependency rules of all layers, checked on the source code of the whole
        /// repository (see the test file for the list).
        .testTarget(name: "ArchitectureTests"),
    ],
    swiftLanguageModes: [.v6]
)
