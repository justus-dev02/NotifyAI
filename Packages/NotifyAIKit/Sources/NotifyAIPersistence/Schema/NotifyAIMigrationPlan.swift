//
//  NotifyAIMigrationPlan.swift
//  NotifyAIPersistence
//

import Foundation
import NotifyAICore
import SwiftData

enum NotifyAIMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [NotifyAISchemaV1.self, NotifyAISchemaV2.self, NotifyAISchemaV3.self, NotifyAISchemaV4.self]
    }
    static var stages: [MigrationStage] { [v1ToV2, v2ToV3, v3ToV4] }

    /// V2 only adds optional attributes, which SwiftData migrates without custom code.
    static var v1ToV2: MigrationStage {
        .lightweight(fromVersion: NotifyAISchemaV1.self, toVersion: NotifyAISchemaV2.self)
    }

    /// The schema change (new entity, renamed and new attributes) is inferred; afterwards
    /// every note's text moves from its row into its own `NoteContent`.
    static var v2ToV3: MigrationStage {
        .custom(fromVersion: NotifyAISchemaV2.self, toVersion: NotifyAISchemaV3.self, willMigrate: nil) { context in
            try moveTextIntoContent(in: context)
        }
    }

    /// Moves `legacyBodyText` into `content`, in batches so a large library never has all
    /// texts in memory at once.
    static func moveTextIntoContent(in context: ModelContext, batchSize: Int = 50) throws {
        var descriptor = FetchDescriptor<NotifyAISchemaV3.Note>(
            predicate: #Predicate { !$0.legacyBodyText.isEmpty },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = batchSize
        while true {
            let batch = try context.fetch(descriptor)
            guard !batch.isEmpty else { break }
            for note in batch {
                let text = note.legacyBodyText
                let content = NotifyAISchemaV3.NoteContent(text: text)
                context.insert(content)
                note.content = content
                note.textLength = text.count
                note.contentRevision = 1
                note.legacyBodyText = ""
            }
            try context.save()
        }
    }

    /// The new entity and relationship are inferred; afterwards the tasks move out of every
    /// summary's JSON into `NoteTask` rows.
    static var v3ToV4: MigrationStage {
        .custom(fromVersion: NotifyAISchemaV3.self, toVersion: NotifyAISchemaV4.self, willMigrate: nil) { context in
            try moveTasksIntoRows(in: context)
        }
    }

    /// Turns the tasks of each summary into `NoteTask` rows and removes them from the JSON,
    /// in batches so a large library is never in memory at once. Notes whose summary cannot
    /// be decoded keep it unchanged.
    static func moveTasksIntoRows(in context: ModelContext, batchSize: Int = 50) throws {
        var descriptor = FetchDescriptor<NotifyAISchemaV4.Note>(
            predicate: #Predicate { $0.summaryData != nil },
            sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]
        )
        descriptor.fetchLimit = batchSize
        var offset = 0
        while true {
            descriptor.fetchOffset = offset
            let batch = try context.fetch(descriptor)
            guard !batch.isEmpty else { break }
            for note in batch {
                guard let data = note.summaryData,
                      let summary = try? JSONDecoder().decode(NoteSummary.self, from: data),
                      !summary.actionItems.isEmpty
                else { continue }
                // The setter writes the rows and the JSON without tasks. The content itself
                // does not change, so the search index keeps the note.
                let revision = note.contentRevision
                note.summary = summary
                note.contentRevision = revision
            }
            try context.save()
            offset += batch.count
        }
    }
}
