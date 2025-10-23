//
//  MindmapView.swift
//  NotifyAI
//
//  Created by Justus on 29.09.25.
//

import SwiftUI

struct MindmapView: View {
    let note: Note
    @EnvironmentObject var appState: AppState
    @State private var zoom: Double = 1.0

    var body: some View {
        VStack(spacing: 16) {
            if let mindmap = note.mindmap {
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    MindmapCanvas(node: mindmap, zoom: zoom)
                        .padding()
                }
            } else {
                Text("Keine Mindmap verfügbar.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Slider(value: $zoom, in: 0.5...2, step: 0.1) {
                    Text("Zoom")
                }
                .frame(maxWidth: 200)
                Spacer()
                Menu {
                    Button("Export als Mermaid") {}
                    Button("Export als PNG") {}
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }

                Button("Expand by AI") {}
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
        }
        .navigationTitle("Mindmap")
    }
}

private struct MindmapCanvas: View {
    let node: Mindmap
    let zoom: Double

    var body: some View {
        VStack(spacing: 24 * zoom) {
            MindmapNodeView(label: node.root, zoom: zoom)
            MindmapBranch(children: node.children, zoom: zoom)
        }
        .scaleEffect(zoom)
    }
}

private struct MindmapBranch: View {
    let children: [MindmapNode]
    let zoom: Double

    var body: some View {
        HStack(alignment: .top, spacing: 32 * zoom) {
            ForEach(children) { node in
                VStack(spacing: 24 * zoom) {
                    MindmapNodeView(label: node.label, zoom: zoom)
                    if let grandchildren = node.children {
                        MindmapBranch(children: grandchildren, zoom: zoom)
                    }
                }
            }
        }
    }
}

private struct MindmapNodeView: View {
    let label: String
    let zoom: Double

    var body: some View {
        Text(label)
            .font(.headline)
            .padding(.horizontal, 16 * zoom)
            .padding(.vertical, 10 * zoom)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16 * zoom, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16 * zoom).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

#Preview {
    let child = MindmapNode(label: "Thema", children: [MindmapNode(label: "Detail", children: nil)])
    let map = Mindmap(root: "Meeting", children: [MindmapNode(label: "Agenda", children: [child])])
    var note = Note(title: "Demo")
    note.mindmap = map
    return MindmapView(note: note)
}
