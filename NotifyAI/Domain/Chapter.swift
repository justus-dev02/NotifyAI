//
//  Chapter.swift
//  NotifyAI
//

import Foundation

/// A section of a long recording, shown as chapter navigation in the summary.
struct SummaryChapter: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var start: TimeInterval
    var end: TimeInterval
    var title: String
    var overview: String

    init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval, title: String, overview: String) {
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
struct ChapterDigest: Codable, Hashable, Sendable {
    var title: String
    var overview: String
    var keyPoints: [String] = []
    var decisions: [String] = []
    var actionItems: [ActionItem] = []
    var openQuestions: [String] = []
    /// Digests of the language model and of the extractive fallback are never mixed up.
    var source: NoteSummary.Source
}
