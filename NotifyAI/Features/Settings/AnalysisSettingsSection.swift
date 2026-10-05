//
//  AnalysisSettingsSection.swift
//  NotifyAI
//

import NotifyAIServices
import SwiftUI

/// Summaries and speakers.
struct AnalysisSettingsSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var analysis = settings.analysis

        Section {
            languageModelStatus
            Toggle(isOn: $analysis.summarizeWhileRecording) {
                SettingLabel(
                    "Lange Aufnahmen schon während der Aufnahme zusammenfassen",
                    detail: "Aufnahmen ab 20 Minuten werden in Kapitel von etwa 10 Minuten geteilt. Fertige Kapitel werden bereits während der Aufnahme verdichtet, damit die Zusammenfassung Sekunden nach dem Stopp bereitsteht. Pausiert automatisch, wenn das Gerät warm wird oder der Stromsparmodus aktiv ist. Benötigt das Live-Transkript."
                )
            }
            .disabled(!settings.transcription.liveTranscription)
            #if os(macOS)
            Toggle(isOn: $analysis.speakersFromAudioSource) {
                SettingLabel(
                    "Sprecher nach Audioquelle trennen",
                    detail: "Bei „Mikrofon + Systemton“ wird deine Stimme als „Ich“ und der Ton der App als „Andere“ beschriftet. Ist genau eine teilnehmende Person eingetragen, erscheint ihr Name."
                )
            }
            #endif
            Toggle(isOn: $analysis.speakerDetection) {
                SettingLabel(
                    "Sprecher erkennen (experimentell)",
                    detail: "Ordnet Abschnitte verschiedenen Stimmen zu. Funktioniert am besten bei deutlich unterschiedlichen Stimmen."
                )
            }
        } header: {
            Text("Auswertung")
        }
    }

    @ViewBuilder
    private var languageModelStatus: some View {
        switch LanguageModelAvailability.current(for: settings.transcription.language) {
        case .available:
            LabeledContent("Zusammenfassung") {
                Label("Apple Intelligence", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .unavailable(let reason):
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Zusammenfassung", value: String(localized: "Einfache Zusammenfassung"))
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A setting's title with an explanation below it.
struct SettingLabel: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    init(_ title: LocalizedStringKey, detail: LocalizedStringKey) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
