//
//  MindmapView.swift
//  NotifyAI
//
//  Created by Justus on 29.09.25.
//

import SwiftUI

struct MindmapView: View {
    let note: Note

    var body: some View {
        List {
            if let mindmap = note.mindmap {
                Section(mindmap.root) {
                    MindmapChildrenView(children: mindmap.children)
                }
            } else {
                Text("Keine Mindmap verfügbar.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Mindmap")
    }
}

private struct MindmapChildrenView: View {
    let children: [MindmapNode]

    var body: some View {
        ForEach(children) { node in
            MindmapNodeRow(node: node)
        }
    }
}

private struct MindmapNodeRow: View {
    let node: MindmapNode

    var body: some View {
        if let children = node.children, !children.isEmpty {
            DisclosureGroup(node.label) {
                MindmapChildrenView(children: children)
            }
        } else {
            Text(node.label)
        }
    }
}

#Preview {
    let child = MindmapNode(label: "Thema", children: [MindmapNode(label: "Detail", children: nil)])
    let map = Mindmap(root: "Meeting", children: [MindmapNode(label: "Agenda", children: [child])])
    var note = Note(title: "Demo")
    note.mindmap = map
    return MindmapView(note: note)
}
