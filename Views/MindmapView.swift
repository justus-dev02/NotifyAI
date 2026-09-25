//
//  MindmapView.swift
//  NotifyAI
//
//  Created by Justus on 29.09.25.
//  Updated for Interactive Zoom, Dynamic Node Layout & Real Mermaid Export.
//

import SwiftUI

struct MindmapView: View {
    let note: Note
    @EnvironmentObject var appState: AppState
    @State private var zoom: Double = 1.0
    @State private var shareURL: URL?

    private let exportService = ExportService()

    var body: some View {
        VStack(spacing: 16) {
            if let mindmap = note.mindmap {
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    MindmapCanvas(node: mindmap, zoom: zoom)
                        .padding(32)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.indigo.opacity(0.6))
                    Text("Keine Mindmap verfügbar.")
                        .font(.headline)
                        .foregroundStyle(Color.adaptiveLabel)
                    Text("Sobald ein Transkript vorliegt, wird hier automatisch eine Wissensstruktur visualisiert.")
                        .font(.caption)
                        .foregroundStyle(Color.adaptiveSecondaryLabel)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
            }

            // Bottom Floating Controls
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(Color.adaptiveSecondaryLabel)

                    Slider(value: $zoom, in: 0.6...1.8, step: 0.1)
                        .accentColor(Color.indigo)
                        .frame(maxWidth: 140)

                    Image(systemName: "plus.magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(Color.adaptiveSecondaryLabel)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())

                Spacer()

                if let mindmap = note.mindmap {
                    Button {
                        if let url = exportService.exportMermaidFile(mindmap: mindmap, title: note.title) {
                            shareURL = url
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up")
                            Text("Mermaid exportieren")
                        }
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color.indigo, in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .liquidGlassBackground()
        .navigationTitle("Mindmap")
        .sheet(item: $shareURL) { url in
            ShareSheet(activityItems: [url])
        }
    }
}

private struct MindmapCanvas: View {
    let node: Mindmap
    let zoom: Double

    var body: some View {
        VStack(spacing: 28 * zoom) {
            MindmapRootNodeView(label: node.root, zoom: zoom)
            MindmapBranch(children: node.children, zoom: zoom)
        }
        .scaleEffect(zoom)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: zoom)
    }
}

private struct MindmapBranch: View {
    let children: [MindmapNode]
    let zoom: Double

    var body: some View {
        HStack(alignment: .top, spacing: 24 * zoom) {
            ForEach(children) { node in
                VStack(spacing: 18 * zoom) {
                    MindmapChildNodeView(label: node.label, zoom: zoom)
                    if let grandchildren = node.children {
                        MindmapBranch(children: grandchildren, zoom: zoom)
                    }
                }
            }
        }
    }
}

private struct MindmapRootNodeView: View {
    let label: String
    let zoom: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .foregroundStyle(.white)
            Text(label)
                .font(.headline)
                .fontWeight(.bold)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 20 * zoom)
        .padding(.vertical, 12 * zoom)
        .background(
            LinearGradient(
                colors: [Color.indigo, Color.purple],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: Capsule()
        )
        .shadow(color: Color.indigo.opacity(0.35), radius: 10, y: 4)
    }
}

private struct MindmapChildNodeView: View {
    let label: String
    let zoom: Double

    var body: some View {
        Text(label)
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundStyle(Color.adaptiveLabel)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14 * zoom)
            .padding(.vertical, 9 * zoom)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14 * zoom, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14 * zoom, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
            )
            .shadow(color: Color.indigo.opacity(0.05), radius: 6, y: 3)
    }
}

#Preview {
    let child = MindmapNode(label: "Detailpunkt", children: nil)
    let map = Mindmap(root: "Projekt Kickoff", children: [MindmapNode(label: "Strategie", children: [child])])
    var note = Note(title: "Demo")
    note.mindmap = map
    return NavigationStack { MindmapView(note: note) }
}
