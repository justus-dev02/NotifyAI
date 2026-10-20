//
//  FoundationModelSummarizer+Prompts.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore

/// The instructions of every request: what to do with which content, in which language.
extension FoundationModelSummarizer {
    enum PromptTask {
        case summary, extractNotes, mergeNotes, chapter
        /// One summary across the summaries of several notes.
        case collection
    }

    static func instructions(for request: SummaryRequest, task: PromptTask) -> String {
        // The language name is given in English ("German") to match the English instructions.
        let languageName = Locale(identifier: "en").localizedString(forLanguageCode: request.language.languageCode)
            ?? "the language of the text"
        let source = switch request.kind {
        case .recording, .audioImport: "a transcript of a spoken conversation"
        case .document, .image: "a document"
        case .collection: "the summaries of several of the user's notes (meetings, conversations, lectures, documents)"
        }

        let taskDescription = switch task {
        case .summary:
            "Summarize \(source) for the person who recorded it."
        case .extractNotes:
            "You receive one excerpt of \(source). Extract structured notes from this excerpt only."
        case .mergeNotes:
            "You receive several sets of notes about \(source). Merge them into one set: combine duplicates and keep every distinct fact, decision and task."
        case .chapter:
            "You receive one chapter of \(source). Condense this chapter only; other chapters are condensed separately."
        case .collection:
            """
            You receive \(source), oldest first. Write one summary across all of them for the user: the overall \
            picture and outcome, how topics developed from note to note, the decisions and what is still open. When \
            it matters, say which note (title or date) a point comes from. Leave the list of tasks empty; the app \
            lists the tasks of the notes itself.
            """
        }

        let date = request.recordedAt.formatted(Date.FormatStyle(date: .complete, time: .shortened).locale(Locale(identifier: "en_US")))
        var context = request.kind == .collection
            ? "Every note has its own date; the latest is from \(date)."
            : "The content was recorded on \(date)."
        if !request.participants.isEmpty {
            context += " Participants: \(request.participants.joined(separator: ", "))."
        }
        if !request.labels.isEmpty {
            context += " The user labeled this content with: \(request.labels.joined(separator: ", ")). Labels name its context, "
                + "such as the company, project or course; use them to understand the content, but state only what the text says."
        }
        if request.kind.hasAudio {
            context += " Lines starting with \"\(SourceSpeakerAttribution.userLabel):\" are spoken by the user who recorded; other labels are the other participants."
        }

        return """
        \(taskDescription)
        \(Self.guidance(for: request))
        \(context)
        Only use information that is stated in the text. Never invent names, numbers, dates or facts. \
        Many recordings are plain minutes, lectures or conversations without tasks, decisions or open \
        questions: then leave those lists empty. A task is only a concrete action that a person in the \
        text explicitly committed to ("I'll send it", "Anna takes care of the budget") or was asked to do \
        ("Could you check the contract by Friday?"). Not tasks: topics, decisions, ideas, wishes, \
        hypothetical or conditional actions ("we could", "maybe", "if"), things already done, and \
        general "next steps". Write each task as a self-contained instruction that starts with a verb \
        and says what exactly is to be done, so it is clear without the conversation. List each task \
        once, even when it was mentioned several times. The owner is the person who will do it: when \
        someone says "I will", it is the label at the start of their line. Leave the owner and deadline \
        empty when they were not said; never write placeholders such as "not specified". \
        Transcripts can contain recognition errors; interpret them sensibly and do not quote them verbatim.
        Be concrete: keep names, numbers, amounts, dates, deadlines and product or project names. \
        Avoid generic statements such as "various topics were discussed". \
        When a deadline is relative ("Friday", "next week"), keep it and add the calendar date based on the recording date.
        Write every field in \(languageName). Be concise and specific.
        """
    }
}
