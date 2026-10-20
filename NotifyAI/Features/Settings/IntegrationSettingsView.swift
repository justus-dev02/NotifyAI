//
//  IntegrationSettingsView.swift
//  NotifyAI
//

import NotifyAIServices
import SwiftUI

/// The entry to the integrations in the settings.
struct IntegrationSettingsSection: View {
    @Environment(IntegrationService.self) private var integrations

    var body: some View {
        Section {
            NavigationLink {
                IntegrationSettingsView()
            } label: {
                LabeledContent("Integrationen") {
                    Text(summary)
                }
            }
        } footer: {
            Text("Notizen in einen Obsidian-Ordner sichern, als Notion-Seite anlegen oder an einen Webhook senden (Zapier, Make, n8n).")
        }
    }

    private var summary: String {
        let configured = IntegrationTarget.allCases.filter(integrations.isConfigured).map(\.name)
        return configured.isEmpty ? String(localized: "Keine") : configured.joined(separator: ", ")
    }
}

/// Obsidian, Notion and webhooks.
struct IntegrationSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(IntegrationService.self) private var integrations
    @State private var isPickingFolder = false
    @State private var notionToken = ""
    @State private var webhookSecret = ""
    @State private var errorMessage: String?

    var body: some View {
        @Bindable var options = settings.integrations

        Form {
            obsidianSection
            notionSection
            webhookSection
            Section {
                Toggle("Transkript mitsenden", isOn: $options.includesTranscript)
                Toggle("Persönliche Daten entfernen", isOn: $options.redactsPersonalData)
            } header: {
                Text("Inhalt")
            } footer: {
                Text("Gilt für Notion und Webhooks; der Obsidian-Ordner erhält immer das Transkript. „Persönliche Daten entfernen“ ersetzt E-Mail-Adressen, Telefonnummern und IBANs, auch in Obsidian.")
            }
        }
        .formStyle(.grouped)
        .settingsPage("Integrationen")
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let folder): perform { try integrations.setObsidianFolder(folder) }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .alert("Nicht gesichert", isPresented: Binding(presenting: $errorMessage)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Obsidian

    @ViewBuilder
    private var obsidianSection: some View {
        @Bindable var options = settings.integrations
        Section {
            LabeledContent("Ordner") {
                Text(options.obsidianFolderName ?? String(localized: "Nicht gewählt"))
            }
            Button(options.obsidianBookmark == nil ? String(localized: "Ordner wählen …") : String(localized: "Anderen Ordner wählen …")) {
                isPickingFolder = true
            }
            if options.obsidianBookmark != nil {
                Toggle("Fertige Notizen automatisch sichern", isOn: $options.obsidianAutomatic)
                Button("Ordner entfernen", role: .destructive) { integrations.removeObsidianFolder() }
            }
        } header: {
            Text("Obsidian")
        } footer: {
            Text("Wähle einen Ordner in deinem Vault. Jede Notiz wird als Markdown-Datei mit Eigenschaften (Datum, Teilnehmende, Schlagwörter) gesichert; erneutes Sichern aktualisiert dieselbe Datei. Der Ordner bleibt auf deinem Gerät.")
        }
    }

    // MARK: Notion

    @ViewBuilder
    private var notionSection: some View {
        @Bindable var options = settings.integrations
        Section {
            if integrations.hasNotionToken {
                LabeledContent("Schlüssel") {
                    Button("Entfernen", role: .destructive) { perform { try integrations.setNotionToken(nil) } }
                }
            } else {
                SecureField("Schlüssel der Integration (ntn_…)", text: $notionToken)
                    .onSubmit(saveNotionToken)
                Button("Schlüssel sichern", action: saveNotionToken)
                    .disabled(notionToken.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            TextField("Link der übergeordneten Seite", text: $options.notionPage)
                .textContentType(.URL)
                .autocorrectionDisabled()
            if !options.notionPage.isEmpty, !IntegrationService.isNotionPage(options.notionPage) {
                Label("Der Link enthält keine Seiten-ID.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if integrations.isConfigured(.notion) {
                Toggle("Fertige Notizen automatisch senden", isOn: $options.notionAutomatic)
            }
        } header: {
            Text("Notion")
        } footer: {
            Text("Lege unter notion.so/profile/integrations eine interne Integration an, kopiere ihren Schlüssel und gib die gewünschte Seite über „Verbindungen“ für sie frei. Notizen werden als Unterseiten angelegt und dabei an Notion übertragen. Der Schlüssel liegt im Schlüsselbund dieses Geräts.")
        }
    }

    private func saveNotionToken() {
        perform {
            try integrations.setNotionToken(notionToken)
            notionToken = ""
        }
    }

    // MARK: Webhook

    @ViewBuilder
    private var webhookSection: some View {
        @Bindable var options = settings.integrations
        Section {
            TextField("https://…", text: $options.webhookURL)
                .textContentType(.URL)
                .autocorrectionDisabled()
            if !options.webhookURL.isEmpty, !integrations.isConfigured(.webhook) {
                Label("Die Adresse muss mit https:// beginnen (http:// nur für localhost).", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if integrations.hasWebhookSecret {
                LabeledContent("Signatur-Geheimnis") {
                    Button("Entfernen", role: .destructive) { perform { try integrations.setWebhookSecret(nil) } }
                }
            } else {
                SecureField("Signatur-Geheimnis (optional)", text: $webhookSecret)
                    .onSubmit(saveWebhookSecret)
                Button("Geheimnis sichern", action: saveWebhookSecret)
                    .disabled(webhookSecret.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if integrations.isConfigured(.webhook) {
                Toggle("Fertige Notizen automatisch senden", isOn: $options.webhookAutomatic)
            }
        } header: {
            Text("Webhook")
        } footer: {
            Text("Fertige Notizen werden als JSON (Zusammenfassung, Aufgaben, Markdown, auf Wunsch das Transkript) per POST an diese Adresse übertragen. Mit Geheimnis trägt jede Anfrage die Signatur X-NotifyAI-Signature (HMAC-SHA256 über Zeitstempel und Inhalt).")
        }
    }

    private func saveWebhookSecret() {
        perform {
            try integrations.setWebhookSecret(webhookSecret)
            webhookSecret = ""
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
