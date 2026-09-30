//
//  AppLaunch.swift
//  NotifyAI
//

import Foundation
import Observation
import OSLog

/// Creates the app environment and offers a way out when that fails.
///
/// The only thing that can stop the environment from being created is a database that
/// cannot be opened (damaged file, failed migration, full disk). Instead of crashing on
/// every launch, the app then shows `DatabaseRecoveryView`: try again, or move the database
/// aside (nothing is deleted) and start with a new one. Recordings live outside the
/// database and are turned into notes again after a reset.
@MainActor
@Observable
final class AppLaunch {
    private(set) var environment: AppEnvironment?
    /// Why the environment could not be created.
    private(set) var failure: String?
    /// Where the previous database was moved after a reset.
    private(set) var movedDatabaseFolder: URL?

    @ObservationIgnored private let makeEnvironment: @MainActor () throws -> AppEnvironment
    @ObservationIgnored private let makeLocations: () throws -> StorageLocations

    init(
        makeEnvironment: @escaping @MainActor () throws -> AppEnvironment = AppEnvironment.makeDefault,
        makeLocations: @escaping () throws -> StorageLocations = StorageLocations.applicationSupport
    ) {
        self.makeEnvironment = makeEnvironment
        self.makeLocations = makeLocations
        attempt()
    }

    /// Tries to create the environment (again).
    func attempt() {
        do {
            environment = try makeEnvironment()
            failure = nil
        } catch {
            environment = nil
            failure = error.localizedDescription
            Logger.persistence.fault("Creating the app environment failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Moves the database aside, starts with a new one and recreates notes for the
    /// recordings that are still on disk.
    func resetDatabase() async {
        do {
            movedDatabaseFolder = try makeLocations().moveDatabaseAside()
        } catch {
            failure = String(localized: "Die Datenbank konnte nicht verschoben werden: \(error.localizedDescription)")
            Logger.persistence.error("Moving the database aside failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        attempt()
        guard let environment else { return }
        do {
            try await environment.store.recoverOrphanedRecordings()
            await environment.start()
        } catch {
            Logger.persistence.error("Recovering recordings failed: \(error.localizedDescription, privacy: .public)")
            environment.notices.post(UserNotice(
                title: String(localized: "Aufnahmen nicht wiederhergestellt"),
                message: String(localized: "Die Aufnahmen liegen weiterhin im Ordner „Recordings“, konnten aber nicht als Notizen angelegt werden: \(error.localizedDescription)")
            ))
        }
    }
}
