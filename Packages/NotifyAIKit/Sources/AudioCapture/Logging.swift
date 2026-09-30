//
//  Logging.swift
//  AudioCapture
//

import OSLog

extension Logger {
    /// The app's subsystem, so capture messages appear next to the app's own.
    public static let capture = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.justus.NotifyAI", category: "Capture")
}

/// Signposts of the capture pipeline, see `Signposts` in the app.
public enum CaptureSignposts {
    public static let processing = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "com.justus.NotifyAI", category: "Capture")
}
