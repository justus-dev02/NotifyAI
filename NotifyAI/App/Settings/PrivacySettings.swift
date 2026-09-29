//
//  PrivacySettings.swift
//  NotifyAI
//

import Foundation
import Observation

/// App lock and backups.
@MainActor
@Observable
final class PrivacySettings {
    private enum Key {
        static let appLock = "privacy.appLock"
        static let includeInBackup = "privacy.includeInBackup"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var appLockEnabled: Bool {
        didSet { defaults.set(appLockEnabled, forKey: Key.appLock) }
    }

    /// Whether recordings and notes are part of iCloud / computer backups. Off by default:
    /// data stays in the app until the user decides otherwise.
    var includeInBackup: Bool {
        didSet { defaults.set(includeInBackup, forKey: Key.includeInBackup) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        appLockEnabled = defaults.bool(forKey: Key.appLock)
        includeInBackup = defaults.bool(forKey: Key.includeInBackup)
    }
}
