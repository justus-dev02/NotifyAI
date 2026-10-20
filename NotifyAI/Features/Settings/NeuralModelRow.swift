//
//  NeuralModelRow.swift
//  NotifyAI
//

import DesignSystem
import NotifyAICore
import NotifyAIServices
import SwiftUI

/// A neural model (speaker recognition, Parakeet) with its download state and actions.
struct NeuralModelRow: View {
    let model: NeuralSpeechModel
    @Environment(NeuralModelManager.self) private var manager
    @State private var isConfirmingDelete = false
    @State private var deleteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.name).font(.body.weight(.semibold))
            Text(model.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            stateView
        }
        .padding(.vertical, 2)
        .confirmationDialog("„\(model.name)“ löschen?", isPresented: $isConfirmingDelete) {
            Button("Löschen", role: .destructive) {
                Task {
                    do {
                        try await manager.delete(model)
                    } catch {
                        deleteError = error.localizedDescription
                    }
                }
            }
        }
        .alert("Modell nicht gelöscht", isPresented: Binding(presenting: $deleteError)) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch manager.state(for: model) {
        case .notInstalled:
            Button("Laden (\(model.approximateSize))") { manager.download(model) }
                .controlSize(.small)
        case .downloading(let progress):
            HStack {
                ProgressView(value: progress)
                Button("Abbrechen") { manager.cancelDownload(of: model) }
                    .controlSize(.small)
            }
        case .preparing:
            HStack(spacing: Theme.Spacing.small) {
                ProgressView().controlSize(.small)
                Text("Wird für dieses Gerät vorbereitet …")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .installed(let bytes):
            HStack {
                Label("Geladen · \(TimeFormatting.byteCount(bytes))", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
                Button("Löschen", role: .destructive) { isConfirmingDelete = true }
                    .controlSize(.small)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(.caption).foregroundStyle(.orange)
                Button("Erneut versuchen") { manager.download(model) }
                    .controlSize(.small)
            }
        }
    }
}
