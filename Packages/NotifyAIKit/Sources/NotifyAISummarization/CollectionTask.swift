//
//  CollectionTask.swift
//  NotifyAISummarization
//

import Foundation
import NotifyAICore
import NotifyAIPersistence
import NotifyAISupport

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

extension CollectionTask {
    /// The tasks of the notes without duplicates, open ones first.
    @MainActor
    package static func tasks(of notes: [Note]) -> [CollectionTask] {
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
}
