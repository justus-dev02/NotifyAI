//
//  ArchitectureTests.swift
//  ArchitectureTests
//
//  The rules of the architecture, checked on the source code of the whole repository.
//
//  The package manifest already makes the compiler enforce the direction of the modules
//  (App → Services → Persistence → Core). These tests cover what the compiler cannot see:
//  which frameworks a layer may use, how the app may touch data, how work leaves the main
//  actor, where platforms may be told apart and that every text is translated. Each rule
//  names the files that break it, so a failure says exactly what to fix.
//

import Foundation
import Testing

// MARK: - Source files

/// The repository root: four levels above this file
/// (Packages/NotifyAIKit/Tests/ArchitectureTests/ArchitectureTests.swift).
private let root = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private struct SourceFile {
    let path: String
    let text: String

    var lines: [String] { text.components(separatedBy: "\n") }

    /// The code without comments, so rules do not match documentation that names a
    /// forbidden pattern.
    var code: String {
        lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { return "" }
            return line
        }
        .joined(separator: "\n")
    }

    var imports: Set<String> {
        Set(lines.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "@preconcurrency ", with: "")
                .replacingOccurrences(of: "@testable ", with: "")
            guard trimmed.hasPrefix("import ") else { return nil }
            return String(trimmed.dropFirst("import ".count))
        })
    }
}

/// All Swift files below the given folders of the repository.
private func sources(in folders: String...) -> [SourceFile] {
    folders.flatMap { folder -> [SourceFile] in
        let directory = root.appending(path: folder)
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { item -> SourceFile? in
            guard let url = item as? URL, url.pathExtension == "swift",
                  !url.path().contains("/.build/"),
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else { return nil }
            return SourceFile(path: url.path().replacingOccurrences(of: root.path(), with: ""), text: text)
        }
    }
}

private let appSources = sources(in: "NotifyAI", "Shared", "NotifyAIWidgets")
private let coreSources = sources(in: "Packages/NotifyAIKit/Sources/NotifyAICore")
private let captureSources = sources(in: "Packages/NotifyAIKit/Sources/AudioCapture")
private let persistenceSources = sources(in: "Packages/NotifyAIKit/Sources/NotifyAIPersistence")
private let serviceSources = sources(in: "Packages/NotifyAIKit/Sources/NotifyAIServices")
private let designSources = sources(in: "Packages/NotifyAIKit/Sources/DesignSystem")
private let packageSources = coreSources + captureSources + persistenceSources + serviceSources + designSources
private let allSources = appSources + packageSources
private let testSources = sources(in: "NotifyAITests", "Packages/NotifyAIKit/Tests/NotifyAICoreTests", "Packages/NotifyAIKit/Tests/AudioCaptureTests")

/// The files of `files` whose code matches `pattern`.
private func violations(of pattern: String, in files: [SourceFile]) -> [String] {
    files.filter { $0.code.range(of: pattern, options: .regularExpression) != nil }.map(\.path)
}

// MARK: - Rules

@Suite("Architecture")
struct ArchitectureTests {
    @Test("The sources were found")
    func sourcesExist() {
        #expect(appSources.count > 30)
        #expect(serviceSources.count > 50)
        #expect(persistenceSources.count > 5)
    }

    // MARK: Layers and frameworks

    @Test("The core uses only Foundation, AVFoundation and logging")
    func coreFrameworks() {
        let allowed: Set = ["Foundation", "AVFoundation", "OSLog"]
        let offenders = coreSources.filter { !$0.imports.isSubset(of: allowed) }.map(\.path)
        #expect(offenders.isEmpty, "Forbidden imports in \(offenders)")
    }

    @Test("The real-time capture knows neither user interface nor data")
    func captureFrameworks() {
        let allowed: Set = ["Foundation", "AVFoundation", "Accelerate", "OSLog", "Synchronization", "NotifyAICore"]
        let offenders = captureSources.filter { !$0.imports.isSubset(of: allowed) }.map(\.path)
        #expect(offenders.isEmpty, "Forbidden imports in \(offenders)")
    }

    @Test("The persistence knows only the core and SwiftData")
    func persistenceFrameworks() {
        let allowed: Set = ["Foundation", "OSLog", "SwiftData", "NotifyAICore"]
        let offenders = persistenceSources.filter { !$0.imports.isSubset(of: allowed) }.map(\.path)
        #expect(offenders.isEmpty, "Forbidden imports in \(offenders)")
    }

    @Test("Services never use SwiftUI")
    func servicesWithoutSwiftUI() {
        let offenders = serviceSources.filter { $0.imports.contains("SwiftUI") }.map(\.path)
        #expect(offenders.isEmpty, "SwiftUI in \(offenders)")
    }

    @Test("Services touch UIKit and AppKit only in platform adapters")
    func platformFrameworksOnlyInAdapters() {
        let adapters = ["/NotifyAIServices/Platform/", "/NotifyAIServices/Audio/SystemAudio/"]
        let offenders = serviceSources
            .filter { !$0.imports.isDisjoint(with: ["UIKit", "AppKit"]) }
            .filter { file in !adapters.contains { file.path.contains($0) } }
            .map(\.path)
        #expect(offenders.isEmpty, "UIKit/AppKit outside the adapters in \(offenders)")
    }

    @Test("The design system knows nothing about data or services")
    func designSystemIsIndependent() {
        let forbidden: Set = ["SwiftData", "NotifyAIPersistence", "NotifyAIServices", "AudioCapture"]
        let offenders = designSources.filter { !$0.imports.isDisjoint(with: forbidden) }.map(\.path)
        #expect(offenders.isEmpty, "Forbidden imports in \(offenders)")
    }

    // MARK: How the app touches data

    @Test("The app never writes the database itself; it calls the services")
    func appDoesNotWriteData() {
        let pattern = #"modelContext|\.save\(\)|\.insert\(|context\.delete|\.rollback\("#
        let offenders = violations(of: pattern, in: appSources)
        #expect(offenders.isEmpty, "Direct database access in \(offenders)")
    }

    @Test("No service locator: views get each object by its own type")
    func noServiceLocator() {
        let offenders = violations(of: #"@Entry\s+var\s+\w+\s*:\s*\w*(Environment|Container|Services)\??"#, in: appSources)
            + violations(of: #"\\\.appEnvironment"#, in: appSources)
        #expect(offenders.isEmpty, "Service locator in \(offenders)")
    }

    // MARK: Concurrency and state

    @Test("Work leaves the main actor structured: no detached tasks")
    func noDetachedTasks() {
        let offenders = violations(of: #"Task\.detached"#, in: allSources)
        #expect(offenders.isEmpty, "Task.detached in \(offenders) – use a @concurrent function or BackgroundWork.run")
    }

    @Test("No mutable global state")
    func noStoredStaticVariables() {
        // `static var name: Type {` is computed and allowed; stored ones are global state.
        let offenders = violations(of: #"static var \w+(\s*:\s*[^{=\n]+)?\s*(=|\n)"#, in: allSources)
        #expect(offenders.isEmpty, "Stored static variables in \(offenders)")
    }

    @Test("Services report through event channels, not through single callback slots")
    func noCallbackSlots() {
        let pattern = #"var\s+on[A-Z]\w*\s*:\s*\(\("#
        let offenders = violations(of: pattern, in: packageSources + appSources)
        #expect(offenders.isEmpty, "Callback slots in \(offenders) – use an EventChannel")
    }

    @Test("@unchecked Sendable only where the type documents its synchronization")
    func uncheckedSendable() {
        let allowed = ["SampleRingBuffer.swift"]
        let offenders = violations(of: #"@unchecked Sendable"#, in: allSources)
            .filter { path in !allowed.contains { path.hasSuffix($0) } }
        #expect(offenders.isEmpty, "@unchecked Sendable in \(offenders)")
    }

    // MARK: Platforms

    @Test("Composition and controllers do not distinguish platforms")
    func noPlatformConditionsInCoreTypes() {
        let files = [
            "AppEnvironment.swift", "AppLifecycle.swift", "ServiceContainer.swift", "RecordingController.swift",
            "AudioRecorder.swift", "ProcessingCoordinator.swift", "NoteStore.swift", "NoteLibrary.swift",
        ]
        let offenders = allSources
            .filter { file in files.contains { file.path.hasSuffix("/" + $0) } }
            .filter { $0.code.contains("#if os(") }
            .map(\.path)
        #expect(offenders.isEmpty, "Platform conditions in \(offenders) – move them into a platform adapter")
    }

    // MARK: Texts

    @Test("Texts of the packages are looked up in their own module's catalog")
    func localizedStringsUseTheModuleBundle() {
        let offenders = packageSources.filter { file in
            file.lines.contains { $0.contains("String(localized:") && !$0.contains("bundle: .module") }
        }
        .map(\.path)
        #expect(offenders.isEmpty, "String(localized:) without bundle: .module in \(offenders)")
    }

    @Test("Every text of the app and the services is translated to English", arguments: [
        "NotifyAI/Localizable.xcstrings",
        "Packages/NotifyAIKit/Sources/NotifyAIServices/Resources/Localizable.xcstrings",
    ])
    func everyTextIsTranslated(catalog: String) throws {
        let data = try Data(contentsOf: root.appending(path: catalog))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: [String: Any]])
        let untranslated = strings.filter { key, entry in
            // Entries marked as not to be translated and stale ones are exempt.
            if entry["shouldTranslate"] as? Bool == false || entry["extractionState"] as? String == "stale" { return false }
            let localizations = entry["localizations"] as? [String: Any]
            let english = (localizations?["en"] as? [String: Any])?["stringUnit"] as? [String: Any]
            let hasVariations = (localizations?["en"] as? [String: Any])?["variations"] != nil
            return english?["state"] as? String != "translated" && !hasVariations && !key.isEmpty
        }
        .map(\.key)
        .sorted()
        #expect(untranslated.isEmpty, "Without English translation: \(untranslated.prefix(20))")
    }

    // MARK: Tests

    @Test("Tests wait for events, never for time")
    func testsDoNotSleep() {
        let offenders = violations(of: #"Task\.sleep|Thread\.sleep|usleep\("#, in: testSources)
        #expect(offenders.isEmpty, "Fixed delays in \(offenders) – wait for the event instead (Waiting.swift)")
    }
}
