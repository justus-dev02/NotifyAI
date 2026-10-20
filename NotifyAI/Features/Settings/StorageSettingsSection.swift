//
//  StorageSettingsSection.swift
//  NotifyAI
//

import DesignSystem
import NotifyAICore
import NotifyAIPersistence
import NotifyAIServices
import SwiftUI

/// Disk usage, how long recordings keep their audio, downloaded models, the search index and
/// deleting all notes.
struct StorageSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(WhisperModelManager.self) private var whisperModels
    @Environment(NeuralModelManager.self) private var neuralModels
    @Environment(RecordingController.self) private var recording
    @Environment(KnowledgeIndexService.self) private var knowledge
    @Environment(NoteLibrary.self) private var library
    @Environment(StorageMaintenance.self) private var storage
    @Environment(UserNotices.self) private var notices
    @Environment(AppNavigation.self) private var navigation
    @State private var recordingsSize: Int64?
    @State private var reservedSpeechPacks: Int?
    @State private var isConfirmingDeleteAll = false
    @State private var isConfirmingDeleteModels = false
    @State private var isDeletingModels = false
    @State private var modelMessage: String?
    /// Recordings whose audio can be deleted, by age.
    @State private var audioScopes: [AudioScope] = []
    @State private var isChoosingAudioScope = false
    /// A retention the user chose that deletes audio right away, awaiting confirmation.
    @State private var pendingRetention: AudioRetention?

    var body: some View {
        Section {
            LabeledContent("Aufnahmen") {
                if let recordingsSize {
                    Text(TimeFormatting.byteCount(recordingsSize))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            Picker("Aufnahmen behalten", selection: retentionBinding) {
                ForEach(AudioRetention.allCases) { retention in
                    Text(retention.title).tag(retention)
                }
            }
            Button("Aufnahmen löschen …", role: .destructive) {
                isChoosingAudioScope = true
            }
            .disabled(audioScopes.isEmpty)
            LabeledContent("Geladene Modelle") {
                Text(modelSummary)
            }
            Button("Geladene Modelle löschen …", role: .destructive) {
                isConfirmingDeleteModels = true
            }
            .disabled(!hasDownloadedModels || isDeletingModels || recording.isActive)
            LabeledContent("Suchindex") {
                if knowledge.isIndexing {
                    ProgressView().controlSize(.small)
                } else {
                    Text("\(knowledge.index.notes.count) Notizen · \(knowledge.index.passageCount) Abschnitte")
                }
            }
            Button("Suchindex neu aufbauen") {
                knowledge.rebuild()
            }
            .disabled(knowledge.isIndexing)
            Button("Alle Notizen löschen …", role: .destructive) {
                isConfirmingDeleteAll = true
            }
            .disabled(recording.isActive)
        } header: {
            Text("Speicher")
        } footer: {
            Text("Beim Löschen von Aufnahmen bleiben Transkript, Zusammenfassung, Aufgaben und Sprecher erhalten; nur das Abspielen und neu Transkribieren entfällt. Automatisch gelöscht werden nur Aufnahmen, die keine Favoriten sind. Modelle lassen sich jederzeit erneut laden.")
        }
        .task {
            await refreshStorage()
        }
        .confirmationDialog("Welche Aufnahmen löschen?", isPresented: $isChoosingAudioScope, titleVisibility: .visible) {
            ForEach(audioScopes) { scope in
                Button(scope.title, role: .destructive) { deleteAudio(scope) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Gelöscht werden nur die Audiodateien, auch die von Favoriten. Transkripte, Zusammenfassungen und Aufgaben bleiben erhalten.")
        }
        .confirmationDialog(
            "Ältere Aufnahmen jetzt löschen?",
            isPresented: Binding(presenting: $pendingRetention),
            titleVisibility: .visible,
            presenting: pendingRetention
        ) { retention in
            Button("Aufnahmen löschen", role: .destructive) { apply(retention) }
            Button("Abbrechen", role: .cancel) { pendingRetention = nil }
        } message: { retention in
            Text(retentionMessage(for: retention))
        }
        .confirmationDialog("Alle Notizen löschen?", isPresented: $isConfirmingDeleteAll, titleVisibility: .visible) {
            Button("Alle löschen", role: .destructive, action: deleteAll)
        } message: {
            Text("Alle Aufnahmen, Transkripte und Zusammenfassungen werden endgültig gelöscht.")
        }
        .confirmationDialog("Geladene Modelle löschen?", isPresented: $isConfirmingDeleteModels, titleVisibility: .visible) {
            Button("Modelle löschen", role: .destructive, action: deleteModels)
        } message: {
            Text("Alle heruntergeladenen Modelle werden entfernt (\(TimeFormatting.byteCount(whisperModels.downloadedBytes + neuralModels.downloadedBytes))): Whisper, Parakeet und das Sprechermodell. Sprachpakete von Apple Speech werden freigegeben; das System entfernt sie, sobald keine andere App sie braucht. Gemerkte Stimmen und deine Notizen bleiben erhalten.")
        }
        .alert("Modelle", isPresented: Binding(presenting: $modelMessage)) {
            Button("OK") { modelMessage = nil }
        } message: {
            Text(modelMessage ?? "")
        }
    }

    private var hasDownloadedModels: Bool {
        whisperModels.downloadedBytes > 0 || neuralModels.downloadedBytes > 0 || (reservedSpeechPacks ?? 0) > 0
    }

    private var modelSummary: String {
        var parts = [String(localized: "Whisper \(TimeFormatting.byteCount(whisperModels.downloadedBytes))")]
        if neuralModels.downloadedBytes > 0 {
            parts.append(String(localized: "Parakeet und Sprecher \(TimeFormatting.byteCount(neuralModels.downloadedBytes))"))
        }
        if let reservedSpeechPacks, reservedSpeechPacks > 0 {
            parts.append(reservedSpeechPacks == 1 ? String(localized: "1 Sprachpaket") : String(localized: "\(reservedSpeechPacks) Sprachpakete"))
        }
        return parts.joined(separator: " · ")
    }

    private func deleteModels() {
        isDeletingModels = true
        Task {
            defer { isDeletingModels = false }
            do {
                try await whisperModels.deleteAll()
                try await neuralModels.deleteAll()
                await AppleSpeechEngine.releaseReservedLocales()
            } catch {
                modelMessage = error.localizedDescription
            }
            await refreshStorage()
        }
    }

    // MARK: Audio

    /// The retention setting; a choice that deletes audio right away asks first.
    private var retentionBinding: Binding<AudioRetention> {
        Binding(
            get: { settings.storage.audioRetention },
            set: { retention in
                if retentionCandidates(for: retention).isEmpty {
                    settings.storage.audioRetention = retention
                } else {
                    pendingRetention = retention
                }
            }
        )
    }

    private func retentionCandidates(for retention: AudioRetention) -> [Note] {
        guard let cutoff = retention.cutoff() else { return [] }
        return library.notesWithAudio(recordedBefore: cutoff, includingFavorites: false)
    }

    private func retentionMessage(for retention: AudioRetention) -> String {
        let count = retentionCandidates(for: retention).count
        return count == 1
            ? String(localized: "Eine Aufnahme ist schon älter und verliert sofort ihre Audiodatei. Transkript, Zusammenfassung und Aufgaben bleiben erhalten; Favoriten behalten ihre Aufnahme.")
            : String(localized: "\(count) Aufnahmen sind schon älter und verlieren sofort ihre Audiodatei. Transkripte, Zusammenfassungen und Aufgaben bleiben erhalten; Favoriten behalten ihre Aufnahme.")
    }

    private func apply(_ retention: AudioRetention) {
        pendingRetention = nil
        settings.storage.audioRetention = retention
        storage.applyAudioRetention()
        Task { await refreshStorage() }
    }

    private func deleteAudio(_ scope: AudioScope) {
        library.deleteAudio(of: library.notesWithAudio(recordedBefore: scope.cutoff))
        Task { await refreshStorage() }
    }

    private func deleteAll() {
        do {
            try library.deleteAll()
        } catch {
            notices.post(UserNotice(title: String(localized: "Nicht gelöscht"), message: String(localized: "Die Notizen konnten nicht gelöscht werden: \(error.localizedDescription)")))
        }
        navigation.selectedNoteID = nil
        Task { await refreshStorage() }
    }

    private func refreshStorage() async {
        await whisperModels.refresh()
        await neuralModels.refresh()
        reservedSpeechPacks = await AppleSpeechEngine.reservedLocales.count
        recordingsSize = await storage.recordingsDiskUsage()
        audioScopes = await AudioScope.available(in: library)
    }
}

/// A group of recordings whose audio can be deleted at once: older than a month, older than
/// three months, or all.
private struct AudioScope: Identifiable {
    let id: Int
    /// Recordings made before this moment; `nil` for all.
    let cutoff: Date?
    let count: Int
    let bytes: Int64

    var title: String {
        let size = TimeFormatting.byteCount(bytes)
        return switch id {
        case 30: String(localized: "Älter als 30 Tage (\(count) · \(size))")
        case 90: String(localized: "Älter als 90 Tage (\(count) · \(size))")
        default: String(localized: "Alle Aufnahmen (\(count) · \(size))")
        }
    }

    /// The scopes that contain recordings, oldest first; a scope with the same recordings as a
    /// wider one is left out.
    @MainActor
    static func available(in library: NoteLibrary, now: Date = .now) async -> [Self] {
        var scopes: [Self] = []
        for days in [0, 30, 90] {
            let cutoff = days > 0 ? Calendar.current.date(byAdding: .day, value: -days, to: now) : nil
            let notes = library.notesWithAudio(recordedBefore: cutoff)
            guard !notes.isEmpty, !scopes.contains(where: { $0.count == notes.count }) else { continue }
            scopes.append(Self(id: days, cutoff: cutoff, count: notes.count, bytes: await library.audioSize(of: notes)))
        }
        return scopes.reversed()
    }
}
