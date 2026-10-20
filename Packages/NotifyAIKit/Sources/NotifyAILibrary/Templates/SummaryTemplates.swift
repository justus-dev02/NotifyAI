//
//  SummaryTemplates.swift
//  NotifyAILibrary
//

import Foundation
import NotifyAICore
import NotifyAIPersistence
import NotifyAIProcessing
import NotifyAISettings
import NotifyAISummarization
import NotifyAISupport
import Observation
import SwiftData

/// Errors when saving a template, shown to the user.
public enum SummaryTemplateError: LocalizedError {
    case emptyName
    case nothingToSummarize

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            String(localized: "Bitte gib der Vorlage einen Namen.", bundle: .module)
        case .nothingToSummarize:
            String(localized: "Wähle mindestens einen Abschnitt oder lege eine eigene Überschrift an.", bundle: .module)
        }
    }
}

/// The templates of the user's own, and which template a note uses.
@MainActor
@Observable
public final class SummaryTemplates {
    /// The fields of a template being edited.
    public struct Draft: Equatable, Sendable {
        public var name = ""
        public var symbolName = "doc.text"
        public var instructions = ""
        public var sections = Set(SummarySection.allCases)
        public var headings: [String] = []

        public init() {}

        public init(_ template: SummaryTemplate) {
            name = template.name
            symbolName = template.symbolName
            instructions = template.instructions
            sections = template.sections
            headings = template.customHeadings
        }
    }

    /// Symbols the user can choose for a template; the built-in templates' symbols included.
    public static let symbols = [
        "doc.text", "text.bubble", "person.3", "person.line.dotted.person", "person.2.wave.2", "briefcase",
        "graduationcap", "stethoscope", "hammer", "chart.bar", "lightbulb", "cart", "phone", "building.2", "heart",
    ]

    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let processing: ProcessingCoordinator
    @ObservationIgnored private let settings: AnalysisSettings

    package init(store: NoteStore, processing: ProcessingCoordinator, settings: AnalysisSettings) {
        self.store = store
        self.processing = processing
        self.settings = settings
    }

    /// A built-in template as the start of one of the user's own, to adapt it.
    public static func draft(basedOn focus: RecordingFocus) -> Draft {
        var draft = Draft()
        draft.name = String(localized: "\(focus.title) (angepasst)", bundle: .module)
        draft.symbolName = focus.symbolName
        draft.instructions = focus.summaryDescription
        return draft
    }

    @discardableResult
    public func create(_ draft: Draft) throws -> SummaryTemplate {
        let fields = try Self.validated(draft)
        let template = SummaryTemplate(
            name: fields.name,
            symbolName: draft.symbolName,
            instructions: fields.instructions,
            sectionsData: SummaryTemplate.encode(draft.sections),
            customHeadings: fields.headings
        )
        try store.insertModel(template)
        return template
    }

    public func update(_ template: SummaryTemplate, with draft: Draft) throws {
        let fields = try Self.validated(draft)
        template.name = fields.name
        template.symbolName = draft.symbolName
        template.instructions = fields.instructions
        template.sections = draft.sections
        template.customHeadings = fields.headings
        template.updatedAt = .now
        try store.save()
    }

    /// Deletes a template. Notes that used it keep their summary; summarized again, they use
    /// their kind of conversation. If it was the default for new recordings, "Allgemein"
    /// takes its place.
    public func delete(_ template: SummaryTemplate) throws {
        let id = template.id
        try store.deleteModel(template)
        if settings.defaultTemplate == .custom(id) {
            settings.defaultTemplate = .focus(.general)
        }
    }

    /// The template a note uses.
    public func choice(for note: Note) -> SummaryTemplateChoice {
        template(for: note).map { .custom($0.id) } ?? .focus(note.focus)
    }

    /// The user's template of a note, if it uses one that still exists.
    public func template(for note: Note) -> SummaryTemplate? {
        note.summaryTemplateID.flatMap(TemplateLookup(store: store).template(id:))
    }

    /// Summarizes the note again with another template.
    public func summarize(_ note: Note, with choice: SummaryTemplateChoice) {
        switch choice {
        case .focus(let focus):
            note.focus = focus
            note.summaryTemplateID = nil
        case .custom(let id):
            note.summaryTemplateID = id
        }
        guard store.saveReportingErrors() else { return }
        processing.enqueue(.resummarize(note.id))
    }

    private static func validated(_ draft: Draft) throws -> (name: String, instructions: String, headings: [String]) {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SummaryTemplateError.emptyName }
        let headings = draft.headings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !draft.sections.isEmpty || !headings.isEmpty else { throw SummaryTemplateError.nothingToSummarize }
        return (name, draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines), headings)
    }
}
