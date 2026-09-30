//
//  DiagnosticsReport.swift
//  NotifyAI
//

import Foundation
import OSLog
#if os(iOS)
import UIKit
#endif

/// A plain-text report for support: versions, device, settings, storage, the app's log of
/// this session and the stored MetricKit reports.
///
/// It contains no note content. The app's log never records transcript or summary text
/// (values that could contain user content are logged as private and appear redacted),
/// and the report is only created and shared when the user asks for it.
enum DiagnosticsReport {
    /// Log entries older than this are left out.
    static let logWindow: TimeInterval = 24 * 60 * 60

    struct Context: Sendable {
        let appVersion: String
        let settingsSummary: [String]
        let locations: StorageLocations?
    }

    static func make(context: Context, now: Date = .now) async -> String {
        await Task.detached(priority: .userInitiated) {
            var lines: [String] = [String(localized: "NotifyAI – Diagnosebericht"), String(localized: "Erstellt: \(now.formatted(.iso8601))"), ""]
            lines += section(String(localized: "App und Gerät"), [
                String(localized: "Version: \(context.appVersion)"),
                String(localized: "System: \(ProcessInfo.processInfo.operatingSystemVersionString)"),
                String(localized: "Gerät: \(deviceModel)"),
                String(localized: "Speicher (RAM): \(ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))"),
                String(localized: "Thermischer Zustand: \(ProcessInfo.processInfo.thermalState.rawValue)"),
                ProcessInfo.processInfo.isLowPowerModeEnabled ? String(localized: "Stromsparmodus: an") : String(localized: "Stromsparmodus: aus"),
            ])
            lines += section(String(localized: "Einstellungen"), context.settingsSummary)
            if let locations = context.locations {
                lines += section(String(localized: "Speicher"), [
                    String(localized: "Aufnahmen: \(ByteCountFormatter.string(fromByteCount: StorageLocations.allocatedSize(of: locations.recordingsDirectory), countStyle: .file))"),
                    String(localized: "Whisper-Modelle: \(ByteCountFormatter.string(fromByteCount: StorageLocations.allocatedSize(of: locations.whisperModelsDirectory), countStyle: .file))"),
                    String(localized: "Suchindex: \(ByteCountFormatter.string(fromByteCount: StorageLocations.allocatedSize(of: locations.knowledgeIndexDirectory), countStyle: .file))"),
                    String(localized: "Frei: \(StorageLocations.availableCapacity(at: locations.root).map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unbekannt")"),
                ])
                let reports = MetricsCollector.storedReports(in: locations.diagnosticsDirectory)
                lines += section(String(localized: "MetricKit-Berichte (\(reports.count))"), reports.prefix(6).map { report in
                    let json = (try? String(contentsOf: report, encoding: .utf8)) ?? String(localized: "nicht lesbar")
                    return "\(report.lastPathComponent)\n\(json)"
                })
            }
            lines += section(String(localized: "Protokoll der laufenden Sitzung"), logEntries(since: now.addingTimeInterval(-logWindow)))
            return lines.joined(separator: "\n")
        }.value
    }

    /// Writes the report to a temporary file for sharing.
    static func writeTemporaryFile(_ report: String, now: Date = .now) throws -> URL {
        let stamp = now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let url = FileManager.default.temporaryDirectory.appending(path: "NotifyAI-Diagnose-\(stamp).txt")
        try Data(report.utf8).write(to: url, options: .atomic)
        return url
    }

    // MARK: - Private

    private static func section(_ title: String, _ lines: [String]) -> [String] {
        ["## \(title)"] + (lines.isEmpty ? ["–"] : lines) + [""]
    }

    /// The app's own log entries of this process. `OSLogStore` only gives access to the
    /// current process, which is exactly the session the user wants to report.
    private static func logEntries(since start: Date) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else {
            return [String(localized: "Das Protokoll ist nicht verfügbar.")]
        }
        let subsystem = Logger.subsystem
        let position = store.position(date: start)
        let predicate = NSPredicate(format: "subsystem == %@", subsystem)
        guard let entries = try? store.getEntries(at: position, matching: predicate) else {
            return [String(localized: "Das Protokoll ist nicht verfügbar.")]
        }
        return entries.compactMap { $0 as? OSLogEntryLog }.suffix(2_000).map { entry in
            "\(entry.date.formatted(.iso8601.time(includingFractionalSeconds: true))) [\(entry.category)] \(level(entry.level)) \(entry.composedMessage)"
        }
    }

    private static func level(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .notice: "NOTICE"
        case .error: "ERROR"
        case .fault: "FAULT"
        default: "–"
        }
    }

    private static var deviceModel: String {
        var size = 0
        let name = "hw.model"
        sysctlbyname(name, nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname(name, &model, &size, nil, 0)
        return String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
