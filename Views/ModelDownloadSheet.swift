//
//  ModelDownloadSheet.swift
//  NotifyAI
//
//  Created by Justus on 23.10.25.
//  Updated for WhisperKit CoreML Speech Recognition Models.
//

import SwiftUI

struct ModelDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var downloadManager = ModelDownloadManager.shared
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerView

                    VStack(spacing: 16) {
                        ForEach(downloadManager.availableModels) { model in
                            modelCard(model)
                        }
                    }
                }
                .padding(20)
            }
            .background(
                LinearGradient(
                    colors: [Color.adaptiveBackground, Color.indigo.opacity(0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .navigationTitle("Whisper Sprachmodelle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Fertig") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var headerView: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 40))
                .foregroundStyle(Color.indigo)
            Text("On-Device Whisper KI")
                .font(.title2)
                .fontWeight(.bold)
            Text("WhisperKit führt OpenAIs modernste Spracherkennungsmodelle direkt auf der Apple Neural Engine deines iPhones aus. 100% offline & datenschutzkonform.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
    }

    private func modelCard(_ model: DownloadableSpeechModel) -> some View {
        let isSelected = settingsViewModel.whisperModel.rawValue == model.id

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(model.name)
                            .font(.headline)
                            .fontWeight(.bold)

                        if isSelected {
                            Text("Aktiv")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.2))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        }
                    }
                    Text("\(model.formattedSize) • \(model.ramRequired)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                Text(model.speedRating)
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.indigo.opacity(0.12))
                    .foregroundStyle(Color.indigo)
                    .clipShape(Capsule())
            }

            Text(model.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                if let variant = WhisperBackend.WhisperModelVariant(rawValue: model.id) {
                    settingsViewModel.whisperModel = variant
                    downloadManager.selectModel(model)
                }
            } label: {
                HStack {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    Text(isSelected ? "Aktiv ausgewählt" : "Dieses Modell aktivieren")
                }
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(isSelected ? .green : .indigo)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(isSelected ? Color.indigo.opacity(0.6) : Color.white.opacity(0.1), lineWidth: 1.5)
        )
    }
}

#Preview {
    ModelDownloadSheet()
        .environmentObject(SettingsViewModel())
}
