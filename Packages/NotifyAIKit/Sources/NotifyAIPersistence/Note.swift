//
//  Note.swift
//  NotifyAIPersistence
//

import Foundation
import NotifyAICore
import SwiftData

public typealias Note = NotifyAISchemaV4.Note
public typealias NoteContent = NotifyAISchemaV4.NoteContent
public typealias NoteTask = NotifyAISchemaV4.NoteTask

// MARK: - Typed accessors

extension Note {
    public package(set) var kind: NoteKind {
        get { NoteKind(rawValue: kindRawValue) ?? .recording }
        set { kindRawValue = newValue.rawValue }
    }

    public package(set) var status: NoteStatus {
        get { NoteStatus(rawValue: statusRawValue) ?? .failed }
        set { statusRawValue = newValue.rawValue }
    }

    public package(set) var focus: RecordingFocus {
        get { RecordingFocus(rawValue: focusRawValue) ?? .general }
        set { focusRawValue = newValue.rawValue }
    }

    public package(set) var language: TranscriptionLanguage {
        get { TranscriptionLanguage(id: languageID) }
        set { languageID = newValue.id }
    }

    public package(set) var transcriptionEngine: TranscriptionEngineKind? {
        get { transcriptionEngineRawValue.flatMap(TranscriptionEngineKind.init(rawValue:)) }
        set { transcriptionEngineRawValue = newValue?.rawValue }
    }

    public var hasTranscript: Bool { transcriptData != nil }

    /// Transcript text or extracted document text. Reading loads `content`; call it only
    /// where the text is needed (detail, export, indexing, summarizing), never in lists.
    public package(set) var bodyText: String {
        get { content?.text ?? "" }
        set {
            if let content {
                content.text = newValue
            } else if !newValue.isEmpty {
                let content = NoteContent(text: newValue)
                modelContext?.insert(content)
                self.content = content
            }
            textLength = newValue.count
            contentRevision += 1
        }
    }

    /// Whether the note has text, without loading it.
    public var hasText: Bool { textLength > 0 }

    public package(set) var audioSource: RecordingAudioSource {
        get { audioSourceRawValue.flatMap(RecordingAudioSource.init(rawValue:)) ?? .microphone }
        set { audioSourceRawValue = newValue.rawValue }
    }

    public package(set) var sourceActivity: SourceActivity? {
        get {
            guard let sourceActivityData else { return nil }
            return try? JSONDecoder().decode(SourceActivity.self, from: sourceActivityData)
        }
        set {
            sourceActivityData = newValue.flatMap { try? JSONEncoder().encode($0) }
        }
    }

    public package(set) var markers: [Marker] {
        get {
            guard let markersData else { return [] }
            return decodingCache.markers(for: markersData)
        }
        set {
            markersData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue.sorted { $0.time < $1.time })
        }
    }

    /// The summary with its tasks. The tasks are stored as `NoteTask` rows, everything else as
    /// JSON; reading joins both, writing splits them.
    ///
    /// Setting a summary counts as a content change (the search index re-indexes the note).
    /// Ticking off a task changes only its `NoteTask` row, which does not.
    public package(set) var summary: NoteSummary? {
        get {
            guard let summaryData, var summary = decodingCache.summary(for: summaryData) else { return nil }
            summary.actionItems = sortedTasks.map(\.actionItem)
            return summary
        }
        set {
            setSummary(newValue)
        }
    }

    /// Stores the summary. `dueDates` resolves the tasks' spoken deadlines; tests pass a
    /// resolver with a fixed calendar.
    package func setSummary(_ summary: NoteSummary?, dueDates: DueDateResolver = DueDateResolver()) {
        replaceTasks(with: summary, dueDates: dueDates)
        var stored = summary
        stored?.actionItems = []
        summaryData = stored.flatMap { try? JSONEncoder().encode($0) }
        summaryOverview = summary?.overview ?? ""
        contentRevision += 1
    }

    /// The tasks in the order of the summary.
    public var sortedTasks: [NoteTask] {
        tasks.sorted { $0.position < $1.position }
    }

    /// Decodes the transcript. Callers should cache the result; decoding a long
    /// transcript is not free.
    public func decodedTranscript() -> [TranscriptSegment] {
        guard let transcriptData else { return [] }
        return (try? Transcript.decode(transcriptData)) ?? []
    }

    /// Stores an already encoded transcript together with its plain text.
    package func setTranscript(encoded data: Data, plainText: String, engine: TranscriptionEngineKind?) {
        transcriptData = data
        bodyText = plainText
        transcriptionEngine = engine
    }

    /// Removes the transcript, e.g. before transcribing again.
    package func clearTranscript() {
        transcriptData = nil
        transcriptionEngine = nil
        bodyText = ""
    }

    package func markFailed(_ message: String) {
        status = .failed
        statusMessage = message
    }

    /// Makes the task rows match the tasks of `summary`: rows of tasks that remain are
    /// updated in place (a task keeps its identity and its row), the others are deleted, new
    /// tasks are inserted. Each spoken deadline is resolved relative to the day the note was
    /// recorded.
    private func replaceTasks(with summary: NoteSummary?, dueDates resolver: DueDateResolver) {
        let items = summary?.actionItems ?? []
        var existing = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var updated: [NoteTask] = []
        for (position, item) in items.enumerated() {
            let dueDate = item.due.flatMap { resolver.resolve($0, relativeTo: createdAt) }
            let sourceTime = summary?.sourceTimes[item.task]
            if let task = existing.removeValue(forKey: item.id) {
                task.task = item.task
                task.owner = item.owner
                task.due = item.due
                task.dueDate = dueDate
                task.isDone = item.isDone
                task.position = position
                task.sourceTime = sourceTime
                updated.append(task)
            } else {
                let task = NoteTask(
                    id: item.id,
                    task: item.task,
                    owner: item.owner,
                    due: item.due,
                    dueDate: dueDate,
                    isDone: item.isDone,
                    position: position,
                    sourceTime: sourceTime
                )
                modelContext?.insert(task)
                updated.append(task)
            }
        }
        for removed in existing.values {
            modelContext?.delete(removed)
        }
        tasks = updated
    }
}

extension NoteTask {
    /// The task as the summary types describe it.
    public var actionItem: ActionItem {
        ActionItem(id: id, task: task, owner: owner, due: due, isDone: isDone)
    }
}
