//
//  ModelDownloadSheet.swift
//  NotifyAI
//
//  Created by Justus on 23.10.25.
//

import SwiftUI

struct LocalAIModel: Identifiable, Hashable {
    let id: String
    let name: String
    let sizeText: String
    let sizeBytes: Double // in MB
    let ramRequired: String
    let speedScore: String
    let description: String
    var isDownloaded: Bool
}

struct ModelDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("activeLLMModelId") private var activeModelId: String = "phi-3-mini"
    
    @State private var models: [LocalAIModel] = [
        LocalAIModel(
            id: "tiny-llm-250m",
            name: "TinyLLM 250M",
            sizeText: "280 MB",
            sizeBytes: 280,
            ramRequired: "~500 MB RAM",
            speedScore: "⚡⚡⚡ Extrem Schnell",
            description: "Ultraschnell und extrem leichtgewichtig. Ideal für einfache Stichpunkte & kurze Aufnahmen.",
            isDownloaded: true
        ),
        LocalAIModel(
            id: "phi-3-mini",
            name: "Phi-3-Mini 3.8B (Q4)",
            sizeText: "1.8 GB",
            sizeBytes: 1800,
            ramRequired: "~2.2 GB RAM",
            speedScore: "⚡⚡ Sehr Schnell (Empfohlen)",
            description: "Bester Kompromiss aus hoher Qualität und Schnelligkeit auf modernen iPhones.",
            isDownloaded: false
        ),
        LocalAIModel(
            id: "mistral-7b-instruct",
            name: "Mistral 7B Instruct (Q4)",
            sizeText: "3.8 GB",
            sizeBytes: 3800,
            ramRequired: "~4.5 GB RAM",
            speedScore: "⚡ Hohe Qualität",
            description: "Sehr hohe Präzision für lange Meetings, Protokolle und komplexe Notizen.",
            isDownloaded: false
        ),
        LocalAIModel(
            id: "llama-3-8b-instruct",
            name: "LLaMA 3 8B Instruct (Q4)",
            sizeText: "4.5 GB",
            sizeBytes: 4500,
            ramRequired: "~5.0 GB RAM",
            speedScore: "🎓 Maximale Präzision",
            description: "Höchste Textqualität & tiefgehende Analysen. Benötigt neuere iPhones (Pro Modell).",
            isDownloaded: false
        )
    ]
    
    @State private var downloadingModelId: String? = nil
    @State private var downloadProgress: Double = 0.0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerView
                    
                    VStack(spacing: 16) {
                        ForEach(models) { model in
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
            .navigationTitle("Lokale KI-Modelle")
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
            Image(systemName: "cpu.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.indigo)
            Text("On-Device LLM-Modelle")
                .font(.title2)
                .fontWeight(.bold)
            Text("Lade KI-Modelle direkt auf dein iPhone herunter. Nach dem Download laufen alle Zusammenfassungen 100% offline ohne Internet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
    }

    private func modelCard(_ model: LocalAIModel) -> some View {
        let isSelected = activeModelId == model.id
        let isDownloading = downloadingModelId == model.id
        
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(model.name)
                            .font(.headline)
                            .fontWeight(.bold)
                        
                        if isSelected {
                            Text("Aktiv")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.2))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        }
                    }
                    Text("\(model.sizeText) • \(model.ramRequired)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                
                Text(model.speedScore)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.indigo.opacity(0.12))
                    .foregroundStyle(Color.indigo)
                    .clipShape(Capsule())
            }

            Text(model.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if isDownloading {
                VStack(spacing: 6) {
                    ProgressView(value: downloadProgress)
                        .tint(.indigo)
                    HStack {
                        Text("Download läuft… \(Int(downloadProgress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(String(format: "%.1f", model.sizeBytes * downloadProgress)) MB / \(model.sizeText)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(spacing: 12) {
                    if model.isDownloaded {
                        Button {
                            activeModelId = model.id
                        } label: {
                            HStack {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                Text(isSelected ? "Aktiv ausgewählt" : "Als aktives Modell nutzen")
                            }
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered)
                        .tint(isSelected ? .green : .indigo)
                    } else {
                        Button {
                            startDownload(model: model)
                        } label: {
                            HStack {
                                Image(systemName: "arrow.down.circle.fill")
                                Text("Herunterladen (\(model.sizeText))")
                            }
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                    }
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(isSelected ? Color.indigo.opacity(0.6) : Color.white.opacity(0.1), lineWidth: 1.5)
        )
    }

    private func startDownload(model: LocalAIModel) {
        downloadingModelId = model.id
        downloadProgress = 0.0
        
        Task {
            for step in 1...50 {
                try? await Task.sleep(nanoseconds: 60_000_000)
                await MainActor.run {
                    downloadProgress = Double(step) / 50.0
                }
            }
            await MainActor.run {
                if let index = models.firstIndex(where: { $0.id == model.id }) {
                    models[index].isDownloaded = true
                }
                activeModelId = model.id
                downloadingModelId = nil
            }
        }
    }
}
