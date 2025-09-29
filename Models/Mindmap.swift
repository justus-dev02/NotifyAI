//
//  Mindmap.swift
//  NotifyAI
//
//  Created by Justus on 29.09.25.
//

import Foundation

struct Mindmap: Codable, Identifiable {
    var id = UUID()
    var root: String
    var children: [MindmapNode]
}
struct MindmapNode: Codable, Identifiable {
    var id = UUID()
    var label: String
    var children: [MindmapNode]?
}
