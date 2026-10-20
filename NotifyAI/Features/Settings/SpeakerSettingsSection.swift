//
//  SpeakerSettingsSection.swift
//  NotifyAI
//

import DesignSystem
import NotifyAIPersistence
import NotifyAIServices
import SwiftData
import SwiftUI

/// Speaker detection, its model and the voices NotifyAI remembers.
struct SpeakerSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(NeuralModelManager.self) private var models
    @Query(sort: \VoiceProfile.name) private var profiles: [VoiceProfile]

    var body: some View {
        @Bindable var analysis = settings.analysis

        Section {
            Toggle(isOn: $analysis.speakerDetection) {
                SettingLabel(
                    "Sprecher erkennen",
                    detail: models.isInstalled(.speakers)
                        ? "Ordnet jedes Wort einer Stimme zu und erkennt Stimmen wieder, die du benannt hast."
                        : "Ohne das Sprechermodell werden nur deutlich unterschiedliche Stimmen getrennt, und Stimmen können nicht wiedererkannt werden."
                )
            }
            NeuralModelRow(model: .speakers)
        } header: {
            Text("Sprecher")
        } footer: {
            Text("Tippe im Transkript auf einen Sprecher, um ihn zu benennen. Mit „Stimme merken“ erkennt NotifyAI die Person in künftigen Aufnahmen und setzt ihren Namen ein. Stimmabdrücke verlassen das Gerät nie.")
        }

        if !profiles.isEmpty {
            Section("Gemerkte Stimmen") {
                ForEach(sortedProfiles) { profile in
                    VoiceProfileRow(profile: profile)
                }
            }
        }
    }

    /// The user's own voice first.
    private var sortedProfiles: [VoiceProfile] {
        profiles.filter(\.isUser) + profiles.filter { !$0.isUser }
    }
}

/// A remembered voice with renaming and forgetting.
private struct VoiceProfileRow: View {
    let profile: VoiceProfile
    @Environment(SpeakerDirectory.self) private var directory
    @State private var isRenaming = false
    @State private var isConfirmingDelete = false
    @State private var draftName = ""
    @State private var errorMessage: String?

    var body: some View {
        HStack {
            Image(systemName: profile.isUser ? "person.fill" : "person")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Aktionen", systemImage: "ellipsis.circle") {
                if !profile.isUser {
                    Button("Umbenennen …", systemImage: "pencil") {
                        draftName = profile.name
                        isRenaming = true
                    }
                }
                Button("Vergessen …", systemImage: "trash", role: .destructive) {
                    isConfirmingDelete = true
                }
            }
            .labelStyle(.iconOnly)
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
        }
        .alert("Stimme umbenennen", isPresented: $isRenaming) {
            TextField("Name", text: $draftName)
            Button("Abbrechen", role: .cancel) {}
            Button("Sichern") { perform { try directory.rename(profile, to: draftName) } }
        } message: {
            Text("Notizen behalten den Namen, den sie haben; neue Aufnahmen erhalten den neuen.")
        }
        .confirmationDialog("„\(profile.name)“ vergessen?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Vergessen", role: .destructive) { perform { try directory.delete(profile) } }
        } message: {
            Text("Die Stimme wird in neuen Aufnahmen nicht mehr erkannt. Bestehende Notizen behalten ihre Namen.")
        }
        .alert("Nicht geändert", isPresented: Binding(presenting: $errorMessage)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var detail: String {
        let learned = profile.sampleCount == 1
            ? String(localized: "Aus 1 Aufnahme gelernt")
            : String(localized: "Aus \(profile.sampleCount) Aufnahmen gelernt")
        return profile.isUser ? String(localized: "Deine Stimme · \(learned)") : learned
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
