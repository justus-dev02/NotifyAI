// swift-tools-version: 6.2
//
// The layers of NotifyAI that do not depend on the app: domain values, the real-time
// capture pipeline and the design system. The compiler enforces the direction of the
// dependencies (app → DesignSystem / AudioCapture → NotifyAICore); nothing here can reach
// back into the app, SwiftData or the services.

import PackageDescription

let package = Package(
    name: "NotifyAIKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "NotifyAICore", targets: ["NotifyAICore"]),
        .library(name: "AudioCapture", targets: ["AudioCapture"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
    ],
    targets: [
        /// Value types and rules: transcripts, markers, summaries, due dates, audio format.
        /// Foundation and AVFoundation only.
        .target(name: "NotifyAICore"),
        /// Lock-free rings for the audio threads and the processing queue that converts,
        /// mixes, encodes and writes. No UI, no persistence.
        .target(name: "AudioCapture", dependencies: ["NotifyAICore"]),
        /// Theme and reusable SwiftUI components.
        .target(name: "DesignSystem", dependencies: ["NotifyAICore"]),
        .testTarget(name: "NotifyAICoreTests", dependencies: ["NotifyAICore"]),
        .testTarget(name: "AudioCaptureTests", dependencies: ["AudioCapture", "NotifyAICore"]),
    ],
    swiftLanguageModes: [.v6]
)
