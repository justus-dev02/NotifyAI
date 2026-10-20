//
//  NoteCollections.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore
import NotifyAIPersistence
import Observation
import SwiftData

/// Which notes a summary across several notes is made from.
public struct CollectionFilter: Equatable, Sendable {
    /// Notes recorded on or after this day.
    public var from: Date?
    /// Notes recorded on or before this day.
    public var through: Date?
    public var label: String?
    /// A participant or named speaker.
    public var person: String?
    /// The kind of conversation or the user's template.
    public var template: SummaryTemplateChoice?

    public init(from: Date? = nil, through: Date? = nil, label: String? = nil, person: String? = nil, template: SummaryTemplateChoice? = nil) {
        self.from = from
        self.through = through
        self.label = label
        self.person = person
        self.template = template
    }
}

/// The tasks of a collection's notes, one entry per task: the same task in several notes
/// (`TaskIdentity`) appears once.
public struct CollectionTask: Identifiable, Sendable {
    /// The task as the first note that mentions it says it.
    public let item: ActionItem
    /// The rows of all notes that mention it; ticking it off ticks off all of them.
    public let taskIDs: [UUID]
    /// The notes it comes from, oldest first.
    public let noteIDs: [UUID]
    public let noteTitles: [String]
    public var id: UUID { item.id }
}

/// Errors when making a summary across several notes, shown to the user.
public enum CollectionError: LocalizedError, Equatable {
    case tooFewNotes
    case emptyTitle

    public var errorDescription: String? {
        switch self {
        case .tooFewNotes:
            String(localized: "Wähle mindestens zwei Notizen mit Zusammenfassung.", bundle: .module)
        case .emptyTitle:
            String(localized: "Bitte gib der Zusammenfassung einen Titel.", bundle: .module)
        }
    }
}

/// Summaries across several notes ("Alle Samsung-Meetings im Oktober").
///
/// A collection is a note of its own (`NoteKind.collection`) that remembers its notes. It is
/// summarized from the notes' summaries, step by step like a long recording, through the
/// processing queue: "Neu zusammenfassen" reads the notes again, so later corrections count.
/// Its tasks are those of its notes, without duplicates and ticked off in the notes
/// themselves, so the task overview never shows a task twice.
@MainActor
@Observable
public final class NoteCollections {
    /// At most this many notes go into one summary. Each note's summary takes about a tenth
    /// of a request; more notes would be condensed so much that little detail remains.
    public static let maximumNotes = 60

    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let processing: ProcessingCoordinator

    init(store: NoteStore, processing: ProcessingCoordinator) {
        self.store = store
        self.processing = processing
    }

    // MARK: Choosing notes

    /// The notes that can be part of a collection, newest first: finished notes with a summary
    /// that match the filter. Collections themselves are left out.
    public func candidates(matching filter: CollectionFilter, calendar: Calendar = .current) -> [Note] {
        let collection = NoteKind.collection.rawValue
        let ready = NoteStatus.ready.rawValue
        let start = filter.from.map { calendar.startOfDay(for: $0) } ?? .distantPast
        let end = filter.through.flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) } ?? .distantFuture
        let labelToken = filter.label.map(NoteLabel.queryToken(for:)) ?? ""
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { note in
                note.kindRawValue != collection && note.statusRawValue == ready && note.summaryData != nil
                    && note.createdAt >= start && note.createdAt < end
                    && (labelToken.isEmpty || note.labelKeys.contains(labelToken))
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return store.fetch(descriptor).filter { note in
            matches(note, person: filter.person) && matches(note, template: filter.template)
        }
    }

    /// The notes with these identifiers that can be part of a collection, newest first.
    public func candidates(withIDs ids: [UUID]) -> [Note] {
        let wanted = Set(ids)
        return candidates(matching: CollectionFilter()).filter { wanted.contains($0.id) }
    }

    /// Participants and named speakers of the notes, for the person filter.
    public func people(in notes: [Note]) -> [String] {
        var seen = Set<String>()
        return notes
            .flatMap { $0.participants + $0.speakers.filter { $0.origin != .detected }.map(\.label) }
            .filter { !TextAnalysis.isSpeakerLabel($0) && seen.insert(TextAnalysis.key($0)).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// A title for the collection: the common label or kind of conversation and the period.
    public func suggestedTitle(for notes: [Note]) -> String {
        let sorted = notes.sorted { $0.createdAt < $1.createdAt }
        guard let first = sorted.first, let last = sorted.last else { return "" }
        let common = first.labels.first { label in notes.allSatisfy { $0.labels.contains { NoteLabel.key($0) == NoteLabel.key(label) } } }
        let subject = common ?? (Set(notes.map(\.focus)).count == 1 && first.focus != .general ? first.focus.title : nil)
        let period = Self.period(from: first.createdAt, to: last.createdAt)
        if let subject {
            return String(localized: "\(subject) · \(period)", bundle: .module)
        }
        return String(localized: "\(notes.count) Notizen · \(period)", bundle: .module)
    }

    // MARK: Making a collection

    /// Makes a collection of the notes and queues its summary.
    /// - Returns: The new note, which shows the progress like any note being processed.
    @discardableResult
    public func create(from notes: [Note], title: String) throws -> Note {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CollectionError.emptyTitle }
        let sources = notes
            .filter { $0.kind != .collection && $0.summary != nil }
            .sorted { $0.createdAt < $1.createdAt }
            .suffix(Self.maximumNotes)
        guard sources.count >= 2 else { throw CollectionError.tooFewNotes }

        let note = Note(
            title: title,
            isTitleUserDefined: true,
            kind: .collection,
            status: .queued,
            language: Self.commonLanguage(of: Array(sources)),
            bodyText: CollectionSource.text(of: sources.compactMap { CollectionSource(note: $0) })
        )
        note.sourceNoteIDs = sources.map(\.id)
        // Labels all notes share describe the collection as well.
        note.setLabels(sources.first?.labels.filter { label in
            sources.allSatisfy { $0.labels.contains { NoteLabel.key($0) == NoteLabel.key(label) } }
        } ?? [])
        try store.insert(note)
        processing.enqueue(.process(note.id))
        return note
    }

    // MARK: A collection's notes and tasks

    /// The notes of a collection that still exist, oldest first.
    public func sources(of collection: Note) -> [Note] {
        Self.sources(of: collection, in: store)
    }

    static func sources(of collection: Note, in store: NoteStore) -> [Note] {
        let ids = collection.sourceNoteIDs
        guard !ids.isEmpty else { return [] }
        let descriptor = FetchDescriptor<Note>(predicate: #Predicate { ids.contains($0.id) }, sortBy: [SortDescriptor(\.createdAt)])
        return store.fetch(descriptor)
    }

    /// The tasks of a collection's notes without duplicates, open ones first.
    public func tasks(of collection: Note) -> [CollectionTask] {
        Self.tasks(of: sources(of: collection))
    }

    /// Ticks a task off or reopens it in every note that mentions it.
    public func setDone(_ task: CollectionTask, _ isDone: Bool) {
        let ids = task.taskIDs
        let rows = store.fetch(FetchDescriptor<NoteTask>(predicate: #Predicate { ids.contains($0.id) }))
        for row in rows {
            row.isDone = isDone
        }
        store.saveReportingErrors()
    }

    static func tasks(of notes: [Note]) -> [CollectionTask] {
        var groups: [(item: ActionItem, ids: [UUID], notes: [(UUID, String)])] = []
        for note in notes.sorted(by: { $0.createdAt < $1.createdAt }) {
            for task in note.sortedTasks {
                if let index = groups.firstIndex(where: { TaskIdentity.matches($0.item.task, task.task) }) {
                    groups[index].ids.append(task.id)
                    if !groups[index].notes.contains(where: { $0.0 == note.id }) {
                        groups[index].notes.append((note.id, note.title))
                    }
                    // Done once it is done everywhere; the owner and deadline of a later mention fill gaps.
                    groups[index].item.isDone = groups[index].item.isDone && task.isDone
                    groups[index].item.owner = groups[index].item.owner ?? task.owner
                    groups[index].item.due = groups[index].item.due ?? task.due
                } else {
                    groups.append((task.actionItem, [task.id], [(note.id, note.title)]))
                }
            }
        }
        let tasks = groups.map { group in
            CollectionTask(item: group.item, taskIDs: group.ids, noteIDs: group.notes.map(\.0), noteTitles: group.notes.map(\.1))
        }
        return tasks.filter { !$0.item.isDone } + tasks.filter(\.item.isDone)
    }

    // MARK: - Private

    private func matches(_ note: Note, person: String?) -> Bool {
        guard let person else { return true }
        let names = note.participants + note.speakers.map(\.label) + note.sortedTasks.compactMap(\.owner)
        return names.contains { HybridRetriever.name($0, matches: person) }
    }

    private func matches(_ note: Note, template: SummaryTemplateChoice?) -> Bool {
        switch template {
        case nil: true
        case .custom(let id): note.summaryTemplateID == id
        case .focus(let focus): note.summaryTemplateID == nil && note.focus == focus
        }
    }

    /// The language most notes are in; summaries are written in it.
    private static func commonLanguage(of notes: [Note]) -> TranscriptionLanguage {
        let counts = Dictionary(grouping: notes, by: \.languageID).mapValues(\.count)
        let id = counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        return id.map(TranscriptionLanguage.init(id:)) ?? .german
    }

    /// "14. Okt. 2026" for one day, "Oktober 2026" for most of a month, "14.–21. Okt. 2026"
    /// otherwise.
    static func period(from start: Date, to end: Date, calendar: Calendar = .current) -> String {
        let range = min(start, end)..<max(start, end)
        if calendar.isDate(start, equalTo: end, toGranularity: .day) {
            return start.formatted(date: .abbreviated, time: .omitted)
        }
        if calendar.isDate(start, equalTo: end, toGranularity: .month),
           range.upperBound.timeIntervalSince(range.lowerBound) > 20 * 86_400 {
            return start.formatted(.dateTime.month(.wide).year())
        }
        return range.formatted(.interval.day().month(.abbreviated).year())
    }
}
