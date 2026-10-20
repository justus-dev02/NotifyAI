//
//  TemplateGuidance.swift
//  NotifyAISummarization
//

import Foundation
import NotifyAICore
import NotifyAIPersistence
import NotifyAISupport
import SwiftData

/// What a template of the user's own asks of a summary.
package struct TemplateGuidance: Equatable, Sendable {
    var name: String
    /// What to pay attention to, in the user's words.
    var instructions: String
    /// The standard sections to generate; the others stay empty.
    var sections: Set<SummarySection>
    /// Headings of the user's own, each filled with points.
    var headings: [String]

    package init(name: String, instructions: String, sections: Set<SummarySection>, headings: [String]) {
        self.name = name
        self.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sections = sections
        self.headings = headings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    @MainActor
    package init(_ template: SummaryTemplate) {
        self.init(name: template.name, instructions: template.instructions, sections: template.sections, headings: template.customHeadings)
    }
}

/// Finds the template of a note in the store.
@MainActor
package struct TemplateLookup {
    let store: NoteStore

    package init(store: NoteStore) {
        self.store = store
    }

    package func template(id: UUID) -> SummaryTemplate? {
        var descriptor = FetchDescriptor<SummaryTemplate>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return store.fetch(descriptor).first
    }

    package func template(for note: Note) -> SummaryTemplate? {
        note.summaryTemplateID.flatMap(template(id:))
    }

    package func guidance(for note: Note) -> TemplateGuidance? {
        note.summaryTemplateID.flatMap(template(id:)).map(TemplateGuidance.init)
    }
}

extension NoteSummary {
    /// The summary without the standard sections the template leaves out.
    func restricted(to sections: Set<SummarySection>) -> NoteSummary {
        var summary = self
        if !sections.contains(.keyPoints) { summary.keyPoints = [] }
        if !sections.contains(.decisions) { summary.decisions = [] }
        if !sections.contains(.actionItems) { summary.actionItems = [] }
        if !sections.contains(.openQuestions) { summary.openQuestions = [] }
        if !sections.contains(.topics) { summary.topics = [] }
        return summary
    }
}
