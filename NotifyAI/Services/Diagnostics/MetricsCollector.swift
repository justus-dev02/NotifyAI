//
//  MetricsCollector.swift
//  NotifyAI
//

import Foundation
import MetricKit
import OSLog

/// Receives MetricKit reports from the system and keeps them on the device.
///
/// The system delivers, at most once a day, what it measured about the app in the field:
/// launch and hang times, CPU and GPU time, disk writes, memory, energy (metrics), plus crash
/// and hang reports with call stacks (diagnostics). Nothing is uploaded: the reports are
/// written to `Diagnostics/` and only leave the device when the user exports a diagnosis
/// report and sends it themselves.
///
/// Uses the subscriber API because the app supports iOS / macOS 26; the Swift
/// `MetricManager` API requires 27.
final class MetricsCollector: NSObject, MXMetricManagerSubscriber, Sendable {
    /// Reports older than this many per kind are removed.
    static let retainedReports = 14

    private let directory: URL

    init(directory: URL) {
        self.directory = directory
        super.init()
    }

    func start() {
        MXMetricManager.shared.add(self)
    }

    func stop() {
        MXMetricManager.shared.remove(self)
    }

    // MARK: MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            store(payload.jsonRepresentation(), kind: "metrics", date: payload.timeStampEnd)
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            store(payload.jsonRepresentation(), kind: "diagnostics", date: payload.timeStampEnd)
        }
    }

    // MARK: Storage

    /// The stored reports, newest first.
    static func storedReports(in directory: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func store(_ json: Data, kind: String, date: Date) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
            try json.write(to: directory.appending(path: "\(kind)-\(stamp).json"), options: .atomic)
            prune(kind: kind)
            Logger.diagnostics.info("Stored a MetricKit \(kind, privacy: .public) report")
        } catch {
            Logger.diagnostics.error("Storing a MetricKit report failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func prune(kind: String) {
        let reports = Self.storedReports(in: directory).filter { $0.lastPathComponent.hasPrefix(kind + "-") }
        for old in reports.dropFirst(Self.retainedReports) {
            try? FileManager.default.removeItem(at: old)
        }
    }
}
