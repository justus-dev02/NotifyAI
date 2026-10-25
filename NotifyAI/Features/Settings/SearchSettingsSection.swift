//
//  SearchSettingsSection.swift
//  NotifyAI
//

import NotifyAIServices
import SwiftUI

/// The model behind "Notizen fragen" and related notes: whether it is installed, with a
/// download button. Like Apple Speech's language packs, it is never loaded without the user.
struct SearchSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(KnowledgeIndexService.self) private var knowledge
    @State private var status: EmbeddingModelStatus?
    @State private var isInstalling = false
    @State private var installError: String?

    private var languageCode: String { settings.transcription.language.languageCode }

    var body: some View {
        Section {
            if let installError {
                Label(installError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            switch status {
            case .installed:
                LabeledContent("Suche nach Bedeutung") {
                    Label("Installiert", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            case .downloadable:
                LabeledContent("Suche nach Bedeutung") {
                    Button(isInstalling ? String(localized: "Wird geladen …") : String(localized: "Jetzt laden"), action: install)
                        .disabled(isInstalling)
                }
            case .unsupported:
                Label("Für \(settings.transcription.language.displayName) sucht NotifyAI nur nach Wörtern.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            case nil:
                ProgressView().controlSize(.small)
            }
        } header: {
            Text("Suche")
        } footer: {
            Text("Ein Sprachmodell von Apple erkennt, was gemeint ist, auch wenn eine Frage andere Worte benutzt als die Notiz, und findet zusammengehörige Notizen. Es wird einmalig von Apple geladen und läuft danach ohne Internet auf diesem Gerät. Nach dem Laden werden alle Notizen im Hintergrund neu durchsucht.")
        }
        .task(id: languageCode) {
            status = knowledge.embeddingModelStatus(for: languageCode)
        }
    }

    private func install() {
        isInstalling = true
        installError = nil
        Task {
            defer { isInstalling = false }
            do {
                if try await !knowledge.installEmbeddingModel(for: languageCode) {
                    installError = String(localized: "Das Modell ist gerade nicht verfügbar. Versuche es später erneut.")
                }
            } catch {
                installError = String(localized: "Das Modell konnte nicht geladen werden: \(error.localizedDescription)")
            }
            status = knowledge.embeddingModelStatus(for: languageCode)
        }
    }
}
