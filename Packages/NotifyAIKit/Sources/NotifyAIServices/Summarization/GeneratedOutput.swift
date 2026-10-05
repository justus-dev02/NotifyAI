//
//  GeneratedOutput.swift
//  NotifyAIServices
//

import Foundation
import FoundationModels
import NotifyAICore

// The structured output the on-device model produces (`@Generable`) and its conversion
// into the app's summary types.

@Generable(description: "Structured notes about part of a text")
struct PartialNotes {
    @Guide(description: "Important facts and statements, each as one short sentence", .maximumCount(8))
    var keyPoints: [String]

    @Guide(description: "Decisions that were explicitly made; empty if none were made", .maximumCount(6))
    var decisions: [String]

    @Guide(description: "Tasks a person explicitly committed to or was asked to do; empty if there are none", .maximumCount(8))
    var actionItems: [GeneratedActionItem]

    @Guide(description: "Questions or problems that were explicitly left open; empty if there are none", .maximumCount(5))
    var openQuestions: [String]

    /// Compact text representation used as input for the next reduce step.
    var promptText: String {
        FoundationModelSummarizer.notesText(
            keyPoints: keyPoints,
            decisions: decisions,
            actionItems: actionItems.map { ActionItem(task: $0.task, owner: $0.owner.nilIfEmpty, due: $0.due.nilIfEmpty) },
            openQuestions: openQuestions
        )
    }
}

@Generable(description: "A concrete action a person explicitly committed to or was asked to do")
struct GeneratedActionItem {
    @Guide(description: "The task, phrased as a short instruction")
    var task: String

    @Guide(description: "Name of the responsible person as it was said; an empty string if nobody was named")
    var owner: String

    @Guide(description: "The deadline as it was said; an empty string if no deadline was mentioned")
    var due: String
}

@Generable(description: "A topic that was discussed")
struct GeneratedTopic {
    @Guide(description: "A short topic title of at most five words")
    var title: String

    @Guide(description: "What was said about the topic", .maximumCount(4))
    var points: [String]
}

@Generable(description: "The condensed content of one chapter of a long recording")
struct GeneratedChapterDigest {
    @Guide(description: "A specific chapter title of at most six words naming its main subject")
    var title: String

    @Guide(description: "One or two sentences on what this chapter is about and its outcome")
    var overview: String

    @Guide(description: "The most important points of this chapter", .maximumCount(5))
    var keyPoints: [String]

    @Guide(description: "Decisions that were explicitly made in this chapter; empty if none were made", .maximumCount(4))
    var decisions: [String]

    @Guide(description: "Tasks a person explicitly committed to or was asked to do in this chapter; empty if there are none", .maximumCount(6))
    var actionItems: [GeneratedActionItem]

    @Guide(description: "Questions or problems explicitly left open in this chapter; empty if there are none", .maximumCount(3))
    var openQuestions: [String]

    func chapterDigest() -> ChapterDigest {
        ChapterDigest(
            title: title.cleaned,
            overview: overview.cleaned,
            keyPoints: keyPoints.cleaned,
            decisions: decisions.cleaned,
            actionItems: actionItems.compactMap { item in
                let task = item.task.cleaned
                guard !task.isEmpty else { return nil }
                return ActionItem(task: task, owner: item.owner.cleaned.nilIfEmpty, due: item.due.cleaned.nilIfEmpty)
            },
            openQuestions: openQuestions.cleaned,
            source: .appleIntelligence
        )
    }
}

@Generable(description: "Summary of a conversation or document")
struct GeneratedSummary {
    @Guide(description: "A specific title of at most seven words")
    var title: String

    @Guide(description: "Two to four sentences describing what the content is about and its outcome")
    var overview: String

    @Guide(description: "The most important points", .maximumCount(7))
    var keyPoints: [String]

    @Guide(description: "Decisions that were explicitly made; empty if none were made", .maximumCount(6))
    var decisions: [String]

    @Guide(description: "Tasks a person explicitly committed to or was asked to do; empty if there are none", .maximumCount(10))
    var actionItems: [GeneratedActionItem]

    @Guide(description: "Questions or problems that were explicitly left open; empty if there are none", .maximumCount(5))
    var openQuestions: [String]

    @Guide(description: "The main topics in the order they came up", .maximumCount(5))
    var topics: [GeneratedTopic]

    @Guide(description: "One to three keywords that identify this content, e.g. the main subject, project, product or customer. Each one to three words, no dates, no generic words like meeting or discussion", .maximumCount(3))
    var keywords: [String]

    func noteSummary() -> NoteSummary {
        NoteSummary(
            suggestedTitle: title.cleaned.nilIfEmpty,
            overview: overview.cleaned,
            keyPoints: keyPoints.cleaned,
            decisions: decisions.cleaned,
            actionItems: actionItems.compactMap { item in
                let task = item.task.cleaned
                guard !task.isEmpty else { return nil }
                return ActionItem(task: task, owner: item.owner.cleaned.nilIfEmpty, due: item.due.cleaned.nilIfEmpty)
            },
            openQuestions: openQuestions.cleaned,
            topics: topics.compactMap { topic in
                let title = topic.title.cleaned
                guard !title.isEmpty else { return nil }
                return SummaryTopic(title: title, points: topic.points.cleaned)
            },
            source: .appleIntelligence,
            keywords: keywords.cleaned
        )
    }
}

private extension String {
    var cleaned: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension [String] {
    var cleaned: [String] { map(\.cleaned).filter { !$0.isEmpty } }
}
