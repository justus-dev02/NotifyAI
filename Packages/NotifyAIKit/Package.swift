// swift-tools-version: 6.2
//
// Everything of NotifyAI below the user interface. The compiler enforces the direction of
// the dependencies; nothing here can reach back into the app:
//
//   App (scenes, views, platform adapters)
//    ├─ DesignSystem ─────────────┐
//    └─ NotifyAIServices          │
//         ├─ NotifyAIPersistence ─┤
//         ├─ AudioCapture ────────┤
//         └─ WhisperKit           └─ NotifyAICore
//
// Access control carries the second rule: models and the store are readable from the app,
// but every write is `package`, so only the services change notes.

import PackageDescription

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
    ],
    targets: [
        /// Value types and rules: transcripts, markers, summaries, due dates, audio format,
        /// logging and the event channel. Foundation and AVFoundation only.
        .target(name: "NotifyAICore"),
        /// Lock-free rings for the audio threads and the processing queue that converts,
        /// mixes, encodes and writes. No UI, no persistence.
        .target(name: "AudioCapture", dependencies: ["NotifyAICore"]),
        /// Theme and reusable SwiftUI components.
        .target(name: "DesignSystem", dependencies: ["NotifyAICore"]),
        /// The SwiftData schema with its migrations, the store and the file layout.
        .target(name: "NotifyAIPersistence", dependencies: ["NotifyAICore"]),
        /// Recording, processing, transcription, summaries, search, import, export, settings
        /// and the use cases the app calls. No SwiftUI.
        .target(
            name: "NotifyAIServices",
            dependencies: [
                "NotifyAICore",
                "NotifyAIPersistence",
                "AudioCapture",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "NotifyAICoreTests", dependencies: ["NotifyAICore"]),
        .testTarget(name: "AudioCaptureTests", dependencies: ["AudioCapture", "NotifyAICore"]),
    ],
    swiftLanguageModes: [.v6]
)
