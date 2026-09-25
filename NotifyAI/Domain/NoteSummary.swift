//
//  NoteSummary.swift
//  NotifyAI
//

import Foundation

/// The structured result of summarizing a note.
struct NoteSummary: Codable, Hashable, Sendable {
    /// Which technique produced the summary. Shown in the UI so users know what to expect.
    enum Source: String, Codable, Sendable {
        /// Apple's on-device foundation model (Apple Intelligence).
        case appleIntelligence
        /// Sentence extraction without a language model (fallback).
        case extractive
    }

    var suggestedTitle: String?
    var overview: String
    var keyPoints: [String]
    var decisions: [String]
    var actionItems: [ActionItem]
    var openQuestions: [String]
    var topics: [SummaryTopic]
    var source: Source
    /// Why the language model was not used, if `source` is `.extractive`.
    var fallbackReason: String?
    var createdAt: Date

    init(
        suggestedTitle: String? = nil,
        overview: String,
        keyPoints: [String] = [],
        decisions: [String] = [],
        actionItems: [ActionItem] = [],
        openQuestions: [String] = [],
        topics: [SummaryTopic] = [],
        source: Source,
        fallbackReason: String? = nil,
        createdAt: Date = .now
    ) {
        self.suggestedTitle = suggestedTitle
        self.overview = overview
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.topics = topics
        self.source = source
        self.fallbackReason = fallbackReason
        self.createdAt = createdAt
    }
}

struct ActionItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var task: String
    var owner: String?
    /// Deadline as it was mentioned ("bis Freitag"). Kept as text because spoken
    /// deadlines are often relative or vague.
    var due: String?
    var isDone: Bool

    init(id: UUID = UUID(), task: String, owner: String? = nil, due: String? = nil, isDone: Bool = false) {
        self.id = id
        self.task = task
        self.owner = owner
        self.due = due
        self.isDone = isDone
    }
}

struct SummaryTopic: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var points: [String]

    init(id: UUID = UUID(), title: String, points: [String]) {
        self.id = id
        self.title = title
        self.points = points
    }
}
