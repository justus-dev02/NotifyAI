//
//  PrivacySettingsSection.swift
//  NotifyAI
//

import NotifyAIServices
import SwiftUI

/// App lock and backups.
struct PrivacySettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppLock.self) private var appLock
    @Environment(StorageMaintenance.self) private var storage

    var body: some View {
        @Bindable var privacy = settings.privacy

        Section {
            Toggle("App mit \(AppLock.biometryName) schützen", isOn: $privacy.appLockEnabled)
                .onChange(of: privacy.appLockEnabled) { _, enabled in
                    if !enabled { appLock.disable() }
                }
            Toggle("In Geräte-Backups einschließen", isOn: $privacy.includeInBackup)
                .onChange(of: privacy.includeInBackup) {
                    storage.applyBackupPreference()
                }
        } header: {
            Text("Datenschutz")
        } footer: {
            // Says what the lock does and what it does not: it hides the notes in the app, the
            // files are protected by the system's encryption only.
            #if os(macOS)
            Text("Die App-Sperre verbirgt deine Notizen in NotifyAI vor anderen an deinem angemeldeten Mac. Die Dateien selbst schützt FileVault; Programme mit Festplattenvollzugriff können sie lesen. Ohne Backup-Freigabe sind sie nicht Teil von Time-Machine-Backups.")
            #else
            Text("Die App-Sperre verbirgt deine Notizen in NotifyAI vor anderen an deinem entsperrten Gerät. Die Dateien selbst schützt die Verschlüsselung des Geräts: Nach einem Neustart sind sie bis zum ersten Entsperren unlesbar, danach bleiben sie lesbar, damit Aufnahme und Verarbeitung auch bei gesperrtem Bildschirm weiterlaufen. Ohne Backup-Freigabe sind sie nicht Teil von iCloud- oder Computer-Backups.")
            #endif
        }
    }
}
