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
    /// One to three keywords that identify the content; used for automatic titles and search.
    var keywords: [String]
    /// Transcript position (seconds) that supports a key point, decision, task or question, by item text.
    var sourceTimes: [String: TimeInterval]

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
        createdAt: Date = .now,
        keywords: [String] = [],
        sourceTimes: [String: TimeInterval] = [:]
    ) {
        self.keywords = keywords
        self.sourceTimes = sourceTimes
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

    private enum CodingKeys: String, CodingKey {
        case suggestedTitle, overview, keyPoints, decisions, actionItems, openQuestions, topics
        case source, fallbackReason, createdAt, keywords, sourceTimes
    }

    /// Summaries saved before `keywords` and `sourceTimes` existed decode with empty values.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        suggestedTitle = try container.decodeIfPresent(String.self, forKey: .suggestedTitle)
        overview = try container.decode(String.self, forKey: .overview)
        keyPoints = try container.decode([String].self, forKey: .keyPoints)
        decisions = try container.decode([String].self, forKey: .decisions)
        actionItems = try container.decode([ActionItem].self, forKey: .actionItems)
        openQuestions = try container.decode([String].self, forKey: .openQuestions)
        topics = try container.decode([SummaryTopic].self, forKey: .topics)
        source = try container.decode(Source.self, forKey: .source)
        fallbackReason = try container.decodeIfPresent(String.self, forKey: .fallbackReason)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        sourceTimes = try container.decodeIfPresent([String: TimeInterval].self, forKey: .sourceTimes) ?? [:]
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
