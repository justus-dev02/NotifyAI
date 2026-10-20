//
//  CollectionSource.swift
//  NotifyAISummarization
//

import Foundation
import NotifyAICore
import NotifyAIPersistence
import NotifyAISupport

/// One note of a summary across several notes: what the summary uses of it.
///
/// The note's own summary stands for the note. It is short and already says what matters, so
/// many notes fit into the few requests the on-device model can take; whole transcripts
/// would not.
package struct CollectionSource: Sendable, Equatable {
    let noteID: UUID
    let title: String
    package let createdAt: Date
    let kind: NoteKind
    /// The kind of conversation or the template, e.g. "Meeting".
    let templateName: String
    let labels: [String]
    let languageCode: String
    let summary: NoteSummary

    @MainActor
    package init?(note: Note, templateName: String? = nil) {
        guard let summary = note.summary else { return nil }
        self.init(
            noteID: note.id,
            title: note.title,
            createdAt: note.createdAt,
            kind: note.kind,
            templateName: templateName ?? note.focus.title,
            labels: note.labels,
            languageCode: note.language.languageCode,
            summary: summary
        )
    }

    package init(
        noteID: UUID = UUID(),
        title: String,
        createdAt: Date,
        kind: NoteKind = .recording,
        templateName: String = "",
        labels: [String] = [],
        languageCode: String = "de",
        summary: NoteSummary
    ) {
        self.noteID = noteID
        self.title = title
        self.createdAt = createdAt
        self.kind = kind
        self.templateName = templateName
        self.labels = labels
        self.languageCode = languageCode
        self.summary = summary
    }

    /// The note for the language model: title, date, kind and labels, then its summary as notes.
    func promptText(number: Int, count: Int) -> String {
        let date = createdAt.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(Locale(identifier: "en_US")))
        var context = [templateName]
        if !labels.isEmpty {
            context.append("labels: " + labels.joined(separator: ", "))
        }
        var lines = ["Note \(number) of \(count): \"\(title)\", \(date) (\(context.filter { !$0.isEmpty }.joined(separator: "; ")))"]
        if !summary.overview.isEmpty {
            lines.append("Summary: \(summary.overview)")
        }
        let sectionPoints = summary.templateSections.flatMap { section in section.points.map { "\(section.title): \($0)" } }
        lines.append(FoundationModelSummarizer.notesText(
            keyPoints: summary.keyPoints + sectionPoints,
            decisions: summary.decisions,
            actionItems: summary.actionItems.filter { !$0.isDone },
            openQuestions: summary.openQuestions
        ))
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The note as a digest, for combining without the language model.
    package var digest: ChapterDigest {
        let date = createdAt.formatted(date: .abbreviated, time: .omitted)
        return ChapterDigest(
            title: "\(title) (\(date))",
            overview: summary.overview,
            keyPoints: summary.keyPoints,
            decisions: summary.decisions,
            actionItems: summary.actionItems.filter { !$0.isDone },
            openQuestions: summary.openQuestions,
            source: .extractive
        )
    }

    /// The text a summary across several notes is made from: every note's summary, oldest
    /// first. Stored as the collection's text; the search index does not index it again.
    package static func text(of sources: [Self]) -> String {
        sources.enumerated()
            .map { index, source in source.promptText(number: index + 1, count: sources.count) }
            .joined(separator: "\n\n")
    }
}
