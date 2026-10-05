//
//  StorageMaintenance.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore
import NotifyAIPersistence
import Observation
import OSLog

/// Disk usage, backups and the diagnosis report: what the settings screen does with the
/// app's files.
@MainActor
@Observable
public final class StorageMaintenance {
    @ObservationIgnored private let locations: StorageLocations
    @ObservationIgnored private let settings: AppSettings

    init(locations: StorageLocations, settings: AppSettings) {
        self.locations = locations
        self.settings = settings
    }

    /// The space the recordings take, in bytes. Scans the folder away from the main actor.
    public func recordingsDiskUsage() async -> Int64 {
        await Self.allocatedSize(of: locations.recordingsDirectory)
    }

    /// Includes or excludes the app's data from device backups, as the privacy setting says.
    public func applyBackupPreference() {
        do {
            try locations.setIncludedInBackup(settings.privacy.includeInBackup)
        } catch {
            Logger.persistence.error("Updating the backup setting failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A plain-text diagnosis report without note content, for the user to share.
    public func makeDiagnosticsReport(appVersion: String) async -> String {
        let context = DiagnosticsReport.Context(
            appVersion: appVersion,
            settingsSummary: settings.diagnosticsSummary,
            locations: locations
        )
        return await DiagnosticsReport.make(context: context)
    }

    @concurrent
    private static func allocatedSize(of directory: URL) async -> Int64 {
        StorageLocations.allocatedSize(of: directory)
    }
}
