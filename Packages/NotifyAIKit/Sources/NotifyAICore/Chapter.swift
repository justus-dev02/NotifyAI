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

    public init(title: String, overview: String, keyPoints: [String] = [], decisions: [String] = [], actionItems: [ActionItem] = [], openQuestions: [String] = [], source: NoteSummary.Source) {
        self.title = title
        self.overview = overview
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.source = source
    }
}
