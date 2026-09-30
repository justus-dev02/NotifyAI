//
//  StorageSettingsSection.swift
//  NotifyAI
//

import DesignSystem
import NotifyAICore
import SwiftUI

/// Disk usage, downloaded models, the search index and deleting all notes.
struct StorageSettingsSection: View {
    @Environment(WhisperModelManager.self) private var whisperModels
    @Environment(RecordingController.self) private var recording
    @Environment(KnowledgeIndexService.self) private var knowledge
    @Environment(\.appEnvironment) private var app
    @State private var recordingsSize: Int64?
    @State private var reservedSpeechPacks: Int?
    @State private var isConfirmingDeleteAll = false
    @State private var isConfirmingDeleteModels = false
    @State private var isDeletingModels = false
    @State private var modelMessage: String?

    var body: some View {
        Section {
            LabeledContent("Aufnahmen") {
                if let recordingsSize {
                    Text(TimeFormatting.byteCount(recordingsSize))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
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
            Text("Modelle lassen sich jederzeit erneut laden. Laufende Aufnahmen und Transkriptionen müssen dafür abgeschlossen sein.")
        }
        .task {
            await refreshStorage()
        }
        .confirmationDialog("Alle Notizen löschen?", isPresented: $isConfirmingDeleteAll, titleVisibility: .visible) {
            Button("Alle löschen", role: .destructive, action: deleteAll)
        } message: {
            Text("Alle Aufnahmen, Transkripte und Zusammenfassungen werden endgültig gelöscht.")
        }
        .confirmationDialog("Geladene Modelle löschen?", isPresented: $isConfirmingDeleteModels, titleVisibility: .visible) {
            Button("Modelle löschen", role: .destructive, action: deleteModels)
        } message: {
            Text("Alle heruntergeladenen Whisper-Modelle werden entfernt (\(TimeFormatting.byteCount(whisperModels.downloadedBytes))). Sprachpakete von Apple Speech werden freigegeben; das System entfernt sie, sobald keine andere App sie braucht. Deine Notizen bleiben erhalten.")
        }
        .alert("Modelle", isPresented: Binding(presenting: $modelMessage)) {
            Button("OK") { modelMessage = nil }
        } message: {
            Text(modelMessage ?? "")
        }
    }

    private var hasDownloadedModels: Bool {
        whisperModels.downloadedBytes > 0 || (reservedSpeechPacks ?? 0) > 0
    }

    private var modelSummary: String {
        var parts = [String(localized: "Whisper \(TimeFormatting.byteCount(whisperModels.downloadedBytes))")]
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
                await AppleSpeechEngine.releaseReservedLocales()
            } catch {
                modelMessage = error.localizedDescription
            }
            await refreshStorage()
        }
    }

    private func deleteAll() {
        app?.processing.cancelAll()
        do {
            try app?.store.deleteAll()
        } catch {
            app?.notices.post(UserNotice(title: String(localized: "Nicht gelöscht"), message: String(localized: "Die Notizen konnten nicht gelöscht werden: \(error.localizedDescription)")))
        }
        app?.navigation.selectedNoteID = nil
        Task { await refreshStorage() }
    }

    private func refreshStorage() async {
        await whisperModels.refresh()
        reservedSpeechPacks = await AppleSpeechEngine.reservedLocales.count
        guard let directory = app?.store.locations.recordingsDirectory else { return }
        recordingsSize = await Task.detached(priority: .utility) {
            StorageLocations.allocatedSize(of: directory)
        }.value
    }
}
