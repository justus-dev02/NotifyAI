//
//  Logging.swift
//  NotifyAI
//

import OSLog

/// Categorised loggers. Use `privacy: .public` only for values that never contain
/// user content; transcript text must not end up in the system log.
extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.justus.NotifyAI"

    static let audio = Logger(subsystem: subsystem, category: "Audio")
    static let transcription = Logger(subsystem: subsystem, category: "Transcription")
    static let summarization = Logger(subsystem: subsystem, category: "Summarization")
    static let processing = Logger(subsystem: subsystem, category: "Processing")
    static let persistence = Logger(subsystem: subsystem, category: "Persistence")
    static let importing = Logger(subsystem: subsystem, category: "Import")
}
