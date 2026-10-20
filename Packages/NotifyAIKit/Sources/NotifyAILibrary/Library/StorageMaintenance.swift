//
//  StorageMaintenance.swift
//  NotifyAILibrary
//

import Foundation
import NotifyAICore
import NotifyAIPersistence
import NotifyAISettings
import NotifyAISupport
import Observation
import OSLog

/// Disk usage, backups, how long recordings keep their audio and the diagnosis report: what
/// the settings screen does with the app's files.
@MainActor
@Observable
public final class StorageMaintenance {
    @ObservationIgnored private let locations: StorageLocations
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let library: NoteLibrary

    package init(locations: StorageLocations, settings: AppSettings, library: NoteLibrary) {
        self.locations = locations
        self.settings = settings
        self.library = library
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

    /// Deletes the audio of recordings older than the retention setting allows. Favorites keep
    /// theirs; text, summary and tasks always stay. Runs at launch and when the setting changes.
    /// - Returns: How many recordings lost their audio.
    @discardableResult
    public func applyAudioRetention(now: Date = .now) -> Int {
        guard let cutoff = settings.storage.audioRetention.cutoff(now: now) else { return 0 }
        let notes = library.notesWithAudio(recordedBefore: cutoff, includingFavorites: false)
        guard !notes.isEmpty, library.deleteAudio(of: notes) else { return 0 }
        Logger.persistence.info("Deleted the audio of \(notes.count, privacy: .public) older recordings")
        return notes.count
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
