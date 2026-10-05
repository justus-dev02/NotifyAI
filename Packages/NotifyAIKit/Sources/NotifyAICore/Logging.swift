//
//  Logging.swift
//  NotifyAICore
//

import Foundation
import OSLog

/// Categorised loggers of all layers. They use the app's subsystem, so the messages of every
/// module appear together. Use `privacy: .public` only for values that never contain user
/// content; transcript text must not end up in the system log.
extension Logger {
    public static let subsystem = Bundle.main.bundleIdentifier ?? "com.justus.NotifyAI"

    public static let audio = Logger(subsystem: subsystem, category: "Audio")
    /// The real-time capture pipeline (`AudioCapture`).
    public static let capture = Logger(subsystem: subsystem, category: "Capture")
    public static let transcription = Logger(subsystem: subsystem, category: "Transcription")
    public static let summarization = Logger(subsystem: subsystem, category: "Summarization")
    public static let processing = Logger(subsystem: subsystem, category: "Processing")
    public static let persistence = Logger(subsystem: subsystem, category: "Persistence")
    public static let importing = Logger(subsystem: subsystem, category: "Import")
    public static let diagnostics = Logger(subsystem: subsystem, category: "Diagnostics")
}

/// Signposts for Instruments ("os_signpost" / Points of Interest).
///
/// Each interval marks work whose cost matters for energy and responsiveness. In Instruments,
/// add the "os_signpost" instrument (or use the Time Profiler, which shows them) and filter
/// by the subsystem; the intervals line up with CPU, disk and energy tracks. Signposts are
/// nearly free when no tool is recording.
public enum Signposts {
    /// One pass of the capture processing queue: convert, mix, encode, write.
    public static let capture = OSSignposter(subsystem: Logger.subsystem, category: "Capture")
    /// Live and file transcription.
    public static let transcription = OSSignposter(subsystem: Logger.subsystem, category: "Transcription")
    /// The processing pipeline after a recording (transcription, speakers, summary).
    public static let processing = OSSignposter(subsystem: Logger.subsystem, category: "Processing")
    /// Search index refreshes and queries.
    public static let knowledge = OSSignposter(subsystem: Logger.subsystem, category: "Knowledge")
}
