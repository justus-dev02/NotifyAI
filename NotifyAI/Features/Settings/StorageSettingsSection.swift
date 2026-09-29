//
//  StorageSettingsSection.swift
//  NotifyAI
//

import SwiftUI

/// Disk usage, the search index and deleting all notes.
struct StorageSettingsSection: View {
    @Environment(WhisperModelManager.self) private var whisperModels
    @Environment(RecordingController.self) private var recording
    @Environment(KnowledgeIndexService.self) private var knowledge
    @Environment(\.appEnvironment) private var app
    @State private var recordingsSize: Int64?
    @State private var isConfirmingDeleteAll = false

    var body: some View {
        Section("Speicher") {
            LabeledContent("Aufnahmen") {
                if let recordingsSize {
                    Text(TimeFormatting.byteCount(recordingsSize))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            LabeledContent("Whisper-Modelle", value: TimeFormatting.byteCount(whisperModels.totalInstalledBytes))
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
        }
        .task {
            await refreshStorage()
        }
        .confirmationDialog("Alle Notizen löschen?", isPresented: $isConfirmingDeleteAll, titleVisibility: .visible) {
            Button("Alle löschen", role: .destructive, action: deleteAll)
        } message: {
            Text("Alle Aufnahmen, Transkripte und Zusammenfassungen werden endgültig gelöscht.")
        }
    }

    private func deleteAll() {
        app?.processing.cancelAll()
        try? app?.store.deleteAll()
        app?.navigation.selectedNoteID = nil
        Task { await refreshStorage() }
    }

    private func refreshStorage() async {
        guard let directory = app?.store.locations.recordingsDirectory else { return }
        recordingsSize = await Task.detached(priority: .utility) {
            StorageLocations.allocatedSize(of: directory)
        }.value
    }
}
