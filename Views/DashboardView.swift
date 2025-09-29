//
//  DashboardView.swift
//  NotifyAI
//
//  Created by Justus on 29.09.25.
//

import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var vm: DashboardViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack {
                    TextField("Suchen (semantisch + Schlagworte)…", text: $vm.query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { vm.performSearch() }
                    Button { vm.newNote() } label: { Image(systemName: "plus.circle.fill") }
                }
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(vm.notes) { n in
                            NoteCard(note: n)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
                                .shadow(radius: 8)
                                .padding(.horizontal)
                        }
                    }
                }
            }
            .navigationTitle("Zusammenfassungen")
        }
    }
}

struct NoteCard: View {
    let note: Note
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(note.title).font(.title3).bold()
                Spacer()
                PipelineChip(state: note.pipeline)
            }
            Text(metaLine(note)).font(.footnote).foregroundStyle(.secondary)
            if let md = note.summary?.markdown {
                Text(md.prefix(160))
                    .lineLimit(4)
            }
            HStack {
                NavigationLink("Transkript") { NoteDetailView(note: note) }
                Spacer()
                NavigationLink("Mindmap") { MindmapView(note: note) }
            }.font(.callout)
        }.padding(16)
    }
    private func metaLine(_ n: Note) -> String {
        let d = DateFormatter.localizedString(from: n.createdAt, dateStyle: .medium, timeStyle: .short)
        let dur = n.duration.map { String(format: "%.0f min", $0/60) } ?? "–"
        return [d, n.location ?? "•", dur].joined(separator: "  ·  ")
    }
}

struct PipelineChip: View {
    let state: PipelineState
    var body: some View {
        HStack(spacing: 6) {
            ProgressView(value: state.progress)
                .frame(width: 44)
            Text(label(for: state.stage))
                .font(.caption2)
        }.padding(6)
         .background(.thinMaterial, in: Capsule())
    }
    private func label(for s: PipelineState.Stage) -> String {
        switch s {
        case .done: return "Fertig"
        case .transcribing: return "ASR"
        case .diarizing: return "Sprecher"
        case .summarizing: return "Summary"
        case .roleSummaries: return "Rollen"
        case .mindmap: return "Mindmap"
        case .indexing: return "Index"
        case .chunking: return "Chunks"
        case .error: return "Fehler"
        default: return "Wartet"
        }
    }
}
