//
//  MacSettingsSections.swift
//  NotifyAI
//

#if os(macOS)
import NotifyAIServices
import SwiftUI

/// Dock and menu bar presence.
struct AppearanceSettingsSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var general = settings.general

        Section {
            Picker("App anzeigen", selection: $general.appPresence) {
                ForEach(AppPresence.allCases) { presence in
                    Text(presence.title).tag(presence)
                }
            }
            .pickerStyle(.radioGroup)
            .onChange(of: general.appPresence) { _, presence in
                AppPresenceController.apply(presence)
            }
        } header: {
            Text("Darstellung")
        } footer: {
            Text(footer(for: general.appPresence))
        }
    }

    private func footer(for presence: AppPresence) -> String {
        switch presence {
        case .dock:
            String(localized: "NotifyAI erscheint wie andere Apps im Dock und im App-Umschalter (⌘⇥). Aufnahmen startest du im Hauptfenster.")
        case .dockAndMenuBar:
            String(localized: "Im Dock für das Hauptfenster, in der Menüleiste für schnelle Aufnahmen – auch wenn das Fenster geschlossen ist.")
        case .menuBar:
            String(localized: "NotifyAI läuft unauffällig in der Menüleiste, ohne Dock-Symbol und ohne App-Menü. Das Hauptfenster öffnest du über „NotifyAI öffnen“ in der Menüleiste, beenden kannst du die App dort über ⏻.")
        }
    }
}

/// The default source of new recordings.
struct RecordingSourceSettingsSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Section {
            AudioSourceRows()
            SystemAudioHints(source: settings.recording.audioSource)
        } header: {
            Text("Aufnahmequelle")
        } footer: {
            Text("\(settings.recording.audioSource.detail) Die Auswahl gilt für neue Aufnahmen und kann vor jeder Aufnahme geändert werden.")
        }
    }
}

/// Automatic and manual updates through Sparkle.
struct UpdateSettingsSection: View {
    @Environment(AppUpdater.self) private var updater

    var body: some View {
        @Bindable var updater = updater

        Section {
            if updater.isConfigured {
                Toggle("Automatisch nach Updates suchen", isOn: $updater.automaticallyChecksForUpdates)
                Picker("Häufigkeit", selection: $updater.checkInterval) {
                    ForEach(UpdateCheckInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
                .disabled(!updater.automaticallyChecksForUpdates)
                Toggle("Updates automatisch laden und installieren", isOn: $updater.automaticallyDownloadsUpdates)
                    .disabled(!updater.automaticallyChecksForUpdates)
                LabeledContent("Zuletzt gesucht") {
                    if let date = updater.lastUpdateCheckDate {
                        Text(date, format: .relative(presentation: .named))
                    } else {
                        Text("Noch nie")
                    }
                }
                Button("Jetzt nach Updates suchen …") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            } else {
                Text("In dieser Version sind keine Updates eingerichtet. Neue Versionen findest du auf GitHub.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Updates")
        } footer: {
            if updater.isConfigured {
                Text("NotifyAI fragt nur eine kleine Versionsliste ab und lädt eine neue Version erst, wenn es eine gibt. Jedes Update ist signiert und wird vor der Installation geprüft. Automatisch geladene Updates werden beim nächsten Beenden installiert – nie während einer Aufnahme. Deine Notizen bleiben erhalten.")
            }
        }
    }
}
#endif
