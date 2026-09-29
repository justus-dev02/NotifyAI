//
//  PrivacySettingsSection.swift
//  NotifyAI
//

import SwiftUI

/// App lock and backups.
struct PrivacySettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppLock.self) private var appLock
    @Environment(\.appEnvironment) private var app

    var body: some View {
        @Bindable var privacy = settings.privacy

        Section {
            Toggle("App mit \(AppLock.biometryName) schützen", isOn: $privacy.appLockEnabled)
                .onChange(of: privacy.appLockEnabled) { _, enabled in
                    if !enabled { appLock.disable() }
                }
            Toggle("In Geräte-Backups einschließen", isOn: $privacy.includeInBackup)
                .onChange(of: privacy.includeInBackup) {
                    app?.applyBackupPreference()
                }
        } header: {
            Text("Datenschutz")
        } footer: {
            Text("Alle Daten liegen ausschließlich im geschützten Speicher dieser App. Ohne Backup-Freigabe sind sie auch nicht Teil von iCloud- oder Computer-Backups.")
        }
    }
}
