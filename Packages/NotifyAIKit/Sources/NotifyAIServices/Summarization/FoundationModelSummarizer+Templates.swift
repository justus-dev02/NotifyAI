//
//  FoundationModelSummarizer+Templates.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore
import OSLog

/// Templates of the user's own: their instructions, the sections they leave out and their
/// headings, which a separate request fills with points.
extension FoundationModelSummarizer {
    /// Fills the headings of the user's template from `source`. A failure costs only these
    /// sections, never the summary, and is noted.
    func fillTemplateSections(of summary: inout NoteSummary, request: SummaryRequest, source: String) async {
        guard let template = request.template, !template.headings.isEmpty else { return }
        do {
            let points = try await responder.respondSections(
                headings: template.headings,
                instructions: Self.sectionInstructions(for: request),
                prompt: source
            )
            summary.templateSections = zip(template.headings, points).map { heading, points in
                SummaryTopic(title: heading, points: points.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            }
        } catch {
            Logger.summarization.error("Filling the template's headings failed: \(error.localizedDescription, privacy: .public)")
            summary.processingNotes.append(String(localized: "Die eigenen Abschnitte der Vorlage „\(template.name)“ konnten nicht ausgefüllt werden.", bundle: .module))
        }
    }

    private static func sectionInstructions(for request: SummaryRequest) -> String {
        let languageName = Locale(identifier: "en").localizedString(forLanguageCode: request.language.languageCode) ?? "the language of the text"
        let source = request.kind.hasAudio ? "a transcript of a spoken conversation" : "a document"
        var instructions = "You receive \(source) or notes about it. "
            + "The output has one list per heading; each heading is given as the description of its list. "
            + "Fill each list with what the text says about that heading, each point as one short, concrete sentence. "
            + "Leave a list empty when the text says nothing about its heading. "
            + "Only use information that is stated in the text; never invent names, numbers or facts. "
            + "Write every point in \(languageName)."
        if let guidance = request.template?.instructions, !guidance.isEmpty {
            instructions += "\nThe user describes what matters to them: \(guidance)"
        }
        return instructions
    }

    /// What the summary should focus on: the user's template, or the kind of conversation.
    static func guidance(for request: SummaryRequest) -> String {
        guard let template = request.template else { return request.focus.modelGuidance }
        var guidance = template.instructions.isEmpty
            ? request.focus.modelGuidance
            : "The user describes what matters to them: \(template.instructions)"
        let omitted = SummarySection.allCases.filter { !template.sections.contains($0) }.map(\.modelName)
        if !omitted.isEmpty {
            guidance += " Leave these lists empty, the user does not want them: \(omitted.joined(separator: ", "))."
        }
        return guidance
    }
}

private extension SummarySection {
    /// The name of the section in the output schema, for the instructions.
    var modelName: String {
        switch self {
        case .keyPoints: "keyPoints"
        case .decisions: "decisions"
        case .actionItems: "actionItems"
        case .openQuestions: "openQuestions"
        case .topics: "topics"
        }
    }
}
