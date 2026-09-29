//
//  AudioAppCatalog.swift
//  NotifyAI
//

#if os(macOS)
import AppKit

/// An app whose audio can be recorded.
struct AudioApp: Identifiable, Hashable, Sendable {
    let bundleID: String
    let name: String
    /// Whether the app (or one of its helpers) is playing audio right now.
    let isPlayingAudio: Bool

    var id: String { bundleID }
    var target: SystemAudioTarget { .app(bundleID: bundleID, name: name) }
}

/// The apps the user can pick as the source of a system audio recording.
@MainActor
enum AudioAppCatalog {
    /// Running apps with a Dock icon, apps playing audio first.
    ///
    /// All regular apps are listed, not only those that already used audio: Zoom or Teams
    /// may not have an audio process yet before a call starts.
    static func runningApps() -> [AudioApp] {
        let processes = CoreAudioObject.audioProcesses()
        let ownBundleID = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AudioApp? in
                guard let bundleID = app.bundleIdentifier, bundleID != ownBundleID, seen.insert(bundleID).inserted else { return nil }
                let matches = AudioProcessMatcher.processes(ofAppWithBundleID: bundleID, bundlePath: app.bundleURL?.path, in: processes)
                return AudioApp(
                    bundleID: bundleID,
                    name: app.localizedName ?? bundleID,
                    isPlayingAudio: matches.contains(where: \.isPlayingAudio)
                )
            }
            .sorted {
                if $0.isPlayingAudio != $1.isPlayingAudio { return $0.isPlayingAudio }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    static func runningApplication(bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    static func icon(bundleID: String) -> NSImage? {
        if let icon = runningApplication(bundleID: bundleID)?.icon {
            return icon
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Opens the privacy pane that lists "Bildschirm- & Systemaudioaufnahme".
    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
#endif
