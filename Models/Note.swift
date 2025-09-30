//
//  Note.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import Foundation
import SwiftUI

struct Note: Identifiable, Codable {
    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, location, duration, audioURL, tags, participants, segments, summary, roleSummaries, mindmap, consent, pipeline, actionItems, highlights, decisions, risks, sourceType, relatedNoteIDs, isFavorite
    }

    let id: UUID
    var title: String
    var createdAt: Date
    var location: String?
    var duration: TimeInterval?
    var audioURL: URL?
    var tags: [String]
    var participants: [Participant]
    var segments: [TranscriptSegment]
    var summary: Summary?
    var roleSummaries: [String: Summary]
    var mindmap: Mindmap?
    var consent: ConsentLog?
    var pipeline: PipelineState
    var actionItems: [ActionItem]
    var highlights: [String]
    var decisions: [String]
    var risks: [String]
    var sourceType: SourceType
    var relatedNoteIDs: [UUID]
    var isFavorite: Bool

    init(id: UUID = UUID(), title: String, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.location = nil
        self.duration = nil
        self.audioURL = nil
        self.tags = []
        self.participants = []
        self.segments = []
        self.summary = nil
        self.roleSummaries = [:]
        self.mindmap = nil
        self.consent = nil
        self.pipeline = .init()
        self.actionItems = []
        self.highlights = []
        self.decisions = []
        self.risks = []
        self.sourceType = .meeting
        self.relatedNoteIDs = []
        self.isFavorite = false
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Unbenannte Notiz"
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        location = try container.decodeIfPresent(String.self, forKey: .location)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        audioURL = try container.decodeIfPresent(URL.self, forKey: .audioURL)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        participants = try container.decodeIfPresent([Participant].self, forKey: .participants) ?? []
        segments = try container.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        summary = try container.decodeIfPresent(Summary.self, forKey: .summary)
        roleSummaries = try container.decodeIfPresent([String: Summary].self, forKey: .roleSummaries) ?? [:]
        mindmap = try container.decodeIfPresent(Mindmap.self, forKey: .mindmap)
        consent = try container.decodeIfPresent(ConsentLog.self, forKey: .consent)
        pipeline = try container.decodeIfPresent(PipelineState.self, forKey: .pipeline) ?? .init()
        actionItems = try container.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
        highlights = try container.decodeIfPresent([String].self, forKey: .highlights) ?? []
        decisions = try container.decodeIfPresent([String].self, forKey: .decisions) ?? []
        risks = try container.decodeIfPresent([String].self, forKey: .risks) ?? []
        sourceType = try container.decodeIfPresent(SourceType.self, forKey: .sourceType) ?? .meeting
        relatedNoteIDs = try container.decodeIfPresent([UUID].self, forKey: .relatedNoteIDs) ?? []
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(location, forKey: .location)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(audioURL, forKey: .audioURL)
        try container.encode(tags, forKey: .tags)
        try container.encode(participants, forKey: .participants)
        try container.encode(segments, forKey: .segments)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encode(roleSummaries, forKey: .roleSummaries)
        try container.encodeIfPresent(mindmap, forKey: .mindmap)
        try container.encodeIfPresent(consent, forKey: .consent)
        try container.encode(pipeline, forKey: .pipeline)
        try container.encode(actionItems, forKey: .actionItems)
        try container.encode(highlights, forKey: .highlights)
        try container.encode(decisions, forKey: .decisions)
        try container.encode(risks, forKey: .risks)
        try container.encode(sourceType, forKey: .sourceType)
        try container.encode(relatedNoteIDs, forKey: .relatedNoteIDs)
        try container.encode(isFavorite, forKey: .isFavorite)
    }
}

struct Participant: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var role: String
    var colorHex: String
    var avatarSymbol: String

    init(id: UUID = UUID(), name: String, role: String, colorHex: String = "#6E5DE7", avatarSymbol: String = "person.crop.circle") {
        self.id = id
        self.name = name
        self.role = role
        self.colorHex = colorHex
        self.avatarSymbol = avatarSymbol
    }
}

extension Participant {
    var color: Color {
        Color(hex: colorHex) ?? .accentColor
    }
}

enum SourceType: String, Codable, CaseIterable, Identifiable {
    case meeting
    case pdf
    case web
    case audio
    case image

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .meeting: return "person.3.fill"
        case .pdf: return "doc.richtext.fill"
        case .web: return "globe"
        case .audio: return "waveform"
        case .image: return "text.viewfinder"
        }
    }

    var displayName: String {
        switch self {
        case .meeting: return "Meeting"
        case .pdf: return "PDF"
        case .web: return "Web"
        case .audio: return "Audio"
        case .image: return "Scan"
        }
    }
}
