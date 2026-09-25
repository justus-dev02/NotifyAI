//
//  Note.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//  Updated for Clean Domain Modeling & State Harmonization.
//

import Foundation
import SwiftUI

struct Note: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var createdAt: Date
    var location: String?
    var context: String?
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
    var sourceType: SourceType
    var relatedNoteIDs: [UUID]
    var isFavorite: Bool

    init(id: UUID = UUID(), title: String = "Neue Notiz", createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.location = nil
        self.context = nil
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
        self.sourceType = .meeting
        self.relatedNoteIDs = []
        self.isFavorite = false
    }

    var actionItems: [ActionItem] {
        get { summary?.actionItems ?? [] }
        set {
            if summary == nil { summary = Summary() }
            summary?.actionItems = newValue
        }
    }

    var highlights: [String] {
        get { summary?.highlights ?? [] }
        set {
            if summary == nil { summary = Summary() }
            summary?.highlights = newValue
        }
    }

    var decisions: [String] {
        get { summary?.decisions ?? [] }
        set {
            if summary == nil { summary = Summary() }
            summary?.decisions = newValue
        }
    }

    var risks: [String] {
        get { summary?.risks ?? [] }
        set {
            if summary == nil { summary = Summary() }
            summary?.risks = newValue
        }
    }
}

struct Participant: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var role: String
    var colorHex: String
    var avatarSymbol: String

    init(id: UUID = UUID(), name: String, role: String = "", colorHex: String = "#6E5DE7", avatarSymbol: String = "person.crop.circle") {
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
