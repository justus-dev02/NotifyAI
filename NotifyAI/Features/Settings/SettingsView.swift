//
//  SettingsView.swift
//  NotifyAI
//

import DesignSystem
import SwiftUI

/// The settings, grouped by topic: tabs in the Mac's settings window, a list of pages on iOS as
/// in the system settings. Each page shows the section views of its topic, each bound only to
/// its settings group.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
        TabView {
            ForEach(SettingsCategory.allCases) { category in
                Tab(category.title, systemImage: category.symbolName) {
                    // A navigation stack for detail pages such as the custom vocabulary.
                    NavigationStack {
                        SettingsCategoryPage(category: category)
                    }
                }
            }
        }
        #else
        List {
            ForEach(SettingsCategory.allCases) { category in
                NavigationLink {
                    SettingsCategoryPage(category: category)
                        .settingsPage(verbatim: category.title)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.title)
                            Text(category.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        SettingsIcon(systemImage: category.symbolName, color: category.color)
                    }
                }
            }
        }
        .navigationTitle("Einstellungen")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Fertig") { dismiss() }
            }
        }
        #endif
    }
}

/// The topics of the settings.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case recording
    case summary
    case speakers
    case labels
    case integrations
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "Allgemein")
        case .recording: String(localized: "Aufnahme")
        case .summary: String(localized: "Zusammenfassung")
        case .speakers: String(localized: "Sprecher")
        case .labels: String(localized: "Labels")
        case .integrations: String(localized: "Integrationen")
        case .privacy: String(localized: "Datenschutz")
        }
    }

    /// What the page contains, below its title in the list on iOS.
    var detail: String {
        switch self {
        case .general: String(localized: "Version, Lizenzen und Diagnosebericht")
        case .recording: String(localized: "Spracherkennung, Sprache und Modelle")
        case .summary: String(localized: "Apple Intelligence, Vorlagen und Suche")
        case .speakers: String(localized: "Sprechererkennung und gemerkte Stimmen")
        case .labels: String(localized: "Umbenennen, zusammenführen, entfernen")
        case .integrations: String(localized: "Obsidian, Notion und Webhooks")
        case .privacy: String(localized: "App-Sperre, Backups und Speicher")
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .recording: "mic"
        case .summary: "sparkles"
        case .speakers: "person.2.wave.2"
        case .labels: "tag"
        case .integrations: "square.and.arrow.up.on.square"
        case .privacy: "lock.shield"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .recording: .red
        case .summary: .purple
        case .speakers: .orange
        case .labels: .blue
        case .integrations: .teal
        case .privacy: .green
        }
    }
}

/// The sections of one topic.
private struct SettingsCategoryPage: View {
    let category: SettingsCategory

    var body: some View {
        switch category {
        case .integrations:
            // A form of its own: it presents the folder picker and its errors.
            IntegrationSettingsView()
        default:
            Form {
                sections
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private var sections: some View {
        switch category {
        case .general:
            #if os(macOS)
            AppearanceSettingsSection()
            UpdateSettingsSection()
            #endif
            AboutSettingsSection()
        case .recording:
            TranscriptionSettingsSection()
            #if os(macOS)
            RecordingSourceSettingsSection()
            #endif
        case .summary:
            AnalysisSettingsSection()
            TemplateSettingsSection()
            SearchSettingsSection()
        case .speakers:
            SpeakerSettingsSection()
        case .labels:
            LabelSettingsSection()
        case .integrations:
            EmptyView()
        case .privacy:
            PrivacySettingsSection()
            StorageSettingsSection()
        }
    }
}

/// Version, licenses and the diagnosis report.
private struct AboutSettingsSection: View {
    var body: some View {
        Section {
            LabeledContent("Version", value: Bundle.main.versionDescription)
            NavigationLink("Lizenzen") {
                LicensesView()
            }
            DiagnosticsExportButton()
        } footer: {
            Text("Der Diagnosebericht enthält Versionen, Einstellungen, Speicherbelegung und das technische Protokoll – keine Inhalte deiner Notizen. Er wird nur gespeichert oder geteilt, wenn du es auswählst.")
        }
    }
}
