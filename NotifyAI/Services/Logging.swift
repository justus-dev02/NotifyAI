//
//  Logging.swift
//  NotifyAI
//

import OSLog

/// Categorised loggers. Use `privacy: .public` only for values that never contain
/// user content; transcript text must not end up in the system log.
extension Logger {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.justus.NotifyAI"

    static let audio = Logger(subsystem: subsystem, category: "Audio")
    static let transcription = Logger(subsystem: subsystem, category: "Transcription")
    static let summarization = Logger(subsystem: subsystem, category: "Summarization")
    static let processing = Logger(subsystem: subsystem, category: "Processing")
    static let persistence = Logger(subsystem: subsystem, category: "Persistence")
    static let importing = Logger(subsystem: subsystem, category: "Import")
    static let diagnostics = Logger(subsystem: subsystem, category: "Diagnostics")
}

/// Signposts for Instruments ("os_signpost" / Points of Interest).
///
/// Each interval marks work whose cost matters for energy and responsiveness. In Instruments,
/// add the "os_signpost" instrument (or use the Time Profiler, which shows them) and filter
/// by the subsystem; the intervals line up with CPU, disk and energy tracks. Signposts are
/// nearly free when no tool is recording.
enum Signposts {
    /// One pass of the capture processing queue: convert, mix, encode, write.
    static let capture = OSSignposter(subsystem: Logger.subsystem, category: "Capture")
    /// Live and file transcription.
    static let transcription = OSSignposter(subsystem: Logger.subsystem, category: "Transcription")
    /// The processing pipeline after a recording (transcription, speakers, summary).
    static let processing = OSSignposter(subsystem: Logger.subsystem, category: "Processing")
    /// Search index refreshes and queries.
    static let knowledge = OSSignposter(subsystem: Logger.subsystem, category: "Knowledge")
}
