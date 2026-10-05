//
//  SettingsView.swift
//  NotifyAI
//

import SwiftUI

/// The settings screen: one section view per topic, each bound only to its settings group.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            TranscriptionSettingsSection()
            #if os(macOS)
            AppearanceSettingsSection()
            RecordingSourceSettingsSection()
            #endif
            AnalysisSettingsSection()
            PrivacySettingsSection()
            StorageSettingsSection()
            #if os(macOS)
            UpdateSettingsSection()
            #endif
            Section {
                LabeledContent("Version", value: Bundle.main.versionDescription)
                DiagnosticsExportButton()
            } footer: {
                Text("Der Diagnosebericht enthält Versionen, Einstellungen, Speicherbelegung und das technische Protokoll – keine Inhalte deiner Notizen. Er wird nur gespeichert oder geteilt, wenn du es auswählst.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Einstellungen")
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Fertig") { dismiss() }
            }
        }
        #endif
    }
}
