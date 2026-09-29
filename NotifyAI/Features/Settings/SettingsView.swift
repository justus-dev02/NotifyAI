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
            Section {
                LabeledContent("Version", value: Bundle.main.versionDescription)
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

private extension Bundle {
    var versionDescription: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
        return "\(version) (\(build))"
    }
}
