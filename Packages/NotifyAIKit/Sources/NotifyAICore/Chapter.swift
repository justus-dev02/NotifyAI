//
//  Chapter.swift
//  NotifyAICore
//

import Foundation

/// A section of a long recording, shown as chapter navigation in the summary.
public struct SummaryChapter: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var title: String
    public var overview: String

    public init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval, title: String, overview: String) {
        self.id = id
        self.start = start
        self.end = end
        self.title = title
        self.overview = overview
    }
}

/// The condensed content of one chapter: the intermediate result of summarizing a long
/// recording. Digests are stored as soon as they exist, so an interrupted summary continues
/// with the next chapter instead of starting over.
public struct ChapterDigest: Codable, Hashable, Sendable {
    public var title: String
    public var overview: String
    public var keyPoints: [String] = []
    public var decisions: [String] = []
    public var actionItems: [ActionItem] = []
    public var openQuestions: [String] = []
    /// Digests of the language model and of the extractive fallback are never mixed up.
    public var source: NoteSummary.Source
    /// Excerpts of the chapter the language model could not process; they were condensed
    /// from their key sentences instead.
    public var failedExcerpts: Int = 0
    /// Whether the chapter's notes had to be cut to fit into the model's context.
    public var wasShortened = false

    public init(
        title: String,
        overview: String,
        keyPoints: [String] = [],
        decisions: [String] = [],
        actionItems: [ActionItem] = [],
        openQuestions: [String] = [],
        source: NoteSummary.Source,
        failedExcerpts: Int = 0,
        wasShortened: Bool = false
    ) {
        self.title = title
        self.overview = overview
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.source = source
        self.failedExcerpts = failedExcerpts
        self.wasShortened = wasShortened
    }

    private enum CodingKeys: String, CodingKey {
        case title, overview, keyPoints, decisions, actionItems, openQuestions, source, failedExcerpts, wasShortened
    }

    /// Digests stored before `failedExcerpts` and `wasShortened` existed decode as complete.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        overview = try container.decode(String.self, forKey: .overview)
        keyPoints = try container.decode([String].self, forKey: .keyPoints)
        decisions = try container.decode([String].self, forKey: .decisions)
        actionItems = try container.decode([ActionItem].self, forKey: .actionItems)
        openQuestions = try container.decode([String].self, forKey: .openQuestions)
        source = try container.decode(NoteSummary.Source.self, forKey: .source)
        failedExcerpts = try container.decodeIfPresent(Int.self, forKey: .failedExcerpts) ?? 0
        wasShortened = try container.decodeIfPresent(Bool.self, forKey: .wasShortened) ?? false
    }
}
