//
//  Note.swift
//  NotifyAIPersistence
//

import Foundation
import NotifyAICore
import SwiftData

public typealias Note = NotifyAISchemaV7.Note
public typealias NoteContent = NotifyAISchemaV7.NoteContent
public typealias NoteTask = NotifyAISchemaV7.NoteTask
public typealias VoiceProfile = NotifyAISchemaV7.VoiceProfile
public typealias SummaryTemplate = NotifyAISchemaV7.SummaryTemplate

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

    /// The speakers of the transcript with their voice prints, in order of first appearance.
    public package(set) var speakers: [NoteSpeaker] {
        get {
            guard let speakersData else { return [] }
            return (try? JSONDecoder().decode([NoteSpeaker].self, from: speakersData)) ?? []
        }
        set {
            speakersData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
        }
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

    /// Removes the transcript and its speakers. The summary and the tasks stay.
    package func clearTranscript() {
        transcriptData = nil
        transcriptionEngine = nil
        bodyText = ""
        speakers = []
        transcriptEditedAt = nil
    }

    package func markFailed(_ message: String) {
        status = .failed
        statusMessage = message
    }

    /// Makes the task rows match the tasks of `summary`.
    ///
    /// A row is reused for the same task (same identifier, or the same task worded anew in a
    /// summary made again, see `TaskIdentity`), so it keeps its identity and whether it is
    /// done. Tasks the user added or changed are never replaced: they stay where the summary
    /// mentions them, or at the end, and a generated task that matches one of them is left
    /// out. The other rows are deleted, new tasks inserted. Each spoken deadline is resolved
    /// relative to the day the note was recorded.
    private func replaceTasks(with summary: NoteSummary?, dueDates resolver: DueDateResolver) {
        let items = summary?.actionItems ?? []
        var userTasks = sortedTasks.filter(\.isUserEdited)
        var generated = sortedTasks.filter { !$0.isUserEdited }
        var updated: [NoteTask] = []
        for item in items {
            if let index = userTasks.firstIndex(where: { $0.id == item.id || TaskIdentity.matches($0.task, item.task) }) {
                // The user's wording wins over the model's.
                updated.append(userTasks.remove(at: index))
                continue
            }
            let dueDate = item.due.flatMap { resolver.resolve($0, relativeTo: createdAt) }
            let sourceTime = summary?.sourceTimes[item.task]
            let match = generated.firstIndex { $0.id == item.id } ?? generated.firstIndex { TaskIdentity.matches($0.task, item.task) }
            if let match {
                let task = generated.remove(at: match)
                // Only an update of the same task carries its state; a new wording keeps the user's tick.
                task.isDone = task.id == item.id ? item.isDone : task.isDone || item.isDone
                task.task = item.task
                task.owner = item.owner
                task.due = item.due
                task.dueDate = dueDate
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
                    position: 0,
                    sourceTime: sourceTime
                )
                modelContext?.insert(task)
                updated.append(task)
            }
        }
        updated += userTasks
        for removed in generated {
            modelContext?.delete(removed)
        }
        for (position, task) in updated.enumerated() {
            task.position = position
        }
        tasks = updated
    }

    // MARK: Tasks of the user's own

    /// Adds a task of the user's own after the others.
    package func appendTask(_ task: String, owner: String?, due: String?, dueDate: Date?) -> NoteTask {
        let row = NoteTask(
            id: UUID(),
            task: task,
            owner: owner,
            due: due,
            dueDate: dueDate,
            isDone: false,
            position: (tasks.map(\.position).max() ?? -1) + 1,
            sourceTime: nil,
            isUserEdited: true
        )
        modelContext?.insert(row)
        tasks.append(row)
        // Tasks are part of what the search index knows about the note.
        contentRevision += 1
        return row
    }

    /// Changes a task; from now on it is the user's and summarizing again keeps it.
    package func editTask(_ row: NoteTask, task: String, owner: String?, due: String?, dueDate: Date?) {
        row.task = task
        row.owner = owner
        row.due = due
        row.dueDate = dueDate
        row.isUserEdited = true
        contentRevision += 1
    }

    package func removeTask(_ row: NoteTask) {
        tasks.removeAll { $0.id == row.id }
        modelContext?.delete(row)
        for (position, task) in sortedTasks.enumerated() {
            task.position = position
        }
        contentRevision += 1
    }

    // MARK: Labels

    /// Replaces the note's labels. They are part of what the search index and the summary
    /// know about the note.
    package func setLabels(_ labels: [String]) {
        let unique = NoteLabel.unique(labels)
        guard unique != self.labels else { return }
        self.labels = unique
        labelKeys = NoteLabel.keyList(of: unique)
        contentRevision += 1
    }

    // MARK: Audio

    /// Whether the note's audio file still exists, so it can be played and transcribed again.
    public var hasAudioFile: Bool { audioFileName != nil }

    /// Forgets the audio file; the caller deletes the file once this is saved.
    package func removeAudio() {
        audioFileName = nil
        audioRemovedAt = .now
    }
}

extension NoteTask {
    /// The task as the summary types describe it.
    public var actionItem: ActionItem {
        ActionItem(id: id, task: task, owner: owner, due: due, isDone: isDone)
    }
}

extension VoiceProfile {
    /// The L2-normalized voice print.
    public var voicePrint: [Float] {
        voicePrintData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    package func setVoicePrint(_ voicePrint: [Float]) {
        voicePrintData = Self.encode(voicePrint)
    }

    package static func encode(_ voicePrint: [Float]) -> Data {
        voicePrint.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

extension SummaryTemplate {
    /// The standard sections the template generates.
    public package(set) var sections: Set<SummarySection> {
        get { (try? JSONDecoder().decode(Set<SummarySection>.self, from: sectionsData)) ?? Set(SummarySection.allCases) }
        set { sectionsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    package static func encode(_ sections: Set<SummarySection>) -> Data {
        (try? JSONEncoder().encode(sections)) ?? Data()
    }
}
