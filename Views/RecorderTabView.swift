//
//  RecorderTabView.swift
//  NotifyAI
//
//  Created by OpenAI Assistant on 05.10.23.
//

import SwiftUI

struct RecorderTabView: View {
    @EnvironmentObject private var notesViewModel: NotesViewModel
    @EnvironmentObject private var dashboardViewModel: DashboardViewModel
    @State private var activeNote: Note?

    private let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "waveform.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Neue Aufnahme starten")
                        .font(.title3.weight(.semibold))
                    Text("Starte eine neue Sitzung, um Sprache lokal mit Apple Speech oder WhisperKit zu transkribieren.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                Button(action: startRecording) {
                    Label("Aufnahme beginnen", systemImage: "mic.fill")
                        .font(.headline)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("start-recording-button")

                if !notesViewModel.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Zuletzt erstellt")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        ForEach(notesViewModel.notes.prefix(3)) { note in
                            NavigationLink {
                                NoteDetailView(note: note)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(note.title)
                                            .font(.subheadline.weight(.semibold))
                                        Text(titleFormatter.string(from: note.createdAt))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    PipelineChip(state: note.pipeline)
                                }
                                .padding(12)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(.white.opacity(0.08))
                                )
                            }
                        }
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.thinMaterial)
                    )
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Recorder")
        }
        .sheet(item: $activeNote, onDismiss: handleDismiss) { note in
            RecorderSheet(note: note)
        }
    }

    private func startRecording() {
        let newTitle = "Sitzung \(titleFormatter.string(from: Date()))"
        let note = notesViewModel.createNew(title: newTitle)
        activeNote = note
        Task { await dashboardViewModel.refresh() }
    }

    private func handleDismiss() {
        Task { await dashboardViewModel.refresh(); await notesViewModel.load() }
    }
}

private struct RecorderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let note: Note

    var body: some View {
        NavigationStack {
            RecorderView(note: note)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Schließen") { dismiss() }
                    }
                }
        }
    }
}

#Preview {
    RecorderTabView()
        .environmentObject(NotesViewModel())
        .environmentObject(DashboardViewModel())
}
