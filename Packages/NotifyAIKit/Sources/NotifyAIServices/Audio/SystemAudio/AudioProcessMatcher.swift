//
//  AudioProcessMatcher.swift
//  NotifyAIServices
//

import Foundation

/// A process known to Core Audio (it has played or recorded audio since it started).
struct AudioProcessInfo: Hashable, Sendable {
    /// The Core Audio process object (`AudioObjectID`).
    let objectID: UInt32
    let pid: Int32
    let bundleID: String?
    let executablePath: String?
    /// Whether the process is currently sending audio to an output device.
    let isPlayingAudio: Bool
}

/// Finds the audio processes that belong to an app.
///
/// Many apps do not play audio from their main process: Chrome, Edge, Discord, Slack and
/// Teams (Chromium/Electron) use helper processes, and Safari plays web audio from the
/// shared WebKit GPU process. A tap on the main process alone would record silence.
enum AudioProcessMatcher {
    /// Apps whose web audio comes from the system's WebKit processes.
    static let webKitBrowsers: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    static let webKitProcessPrefix = "com.apple.WebKit."

    static func processes(
        ofAppWithBundleID bundleID: String,
        bundlePath: String?,
        in processes: [AudioProcessInfo]
    ) -> [AudioProcessInfo] {
        processes.filter { belongs($0, toAppWithBundleID: bundleID, bundlePath: bundlePath) }
    }

    static func belongs(_ process: AudioProcessInfo, toAppWithBundleID bundleID: String, bundlePath: String?) -> Bool {
        if let processBundleID = process.bundleID {
            // The app itself and helpers such as "com.google.Chrome.helper".
            if processBundleID == bundleID || processBundleID.hasPrefix(bundleID + ".") {
                return true
            }
            if webKitBrowsers.contains(bundleID), processBundleID.hasPrefix(webKitProcessPrefix) {
                return true
            }
        }
        // Helpers inside the app bundle, e.g. ".../Zoom.app/Contents/Frameworks/…".
        if let bundlePath, let executablePath = process.executablePath {
            let prefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
            if executablePath.hasPrefix(prefix) {
                return true
            }
        }
        return false
    }
}
