//
//  NoteAssistant.swift
//  NotifyAI
//

import Foundation
import FoundationModels

/// A numbered excerpt the answer may use.
struct AssistantSource: Sendable {
    let number: Int
    let noteTitle: String
    let noteDate: Date
    let start: TimeInterval?
    let text: String
}

/// A previous question and answer, for follow-up questions ("Und was hat sie dazu gesagt?").
struct ChatTurn: Sendable {
    let question: String
    let answer: String
}

/// The language model's reading of a question.
struct AssistantPlan: Sendable, Equatable {
    var searchQuery: String
    var relatedTerms: [String]
    var persons: [String]
    var timeframe: Timeframe
    var wantsList: Bool
}

struct AssistantAnswer: Sendable, Equatable {
    var text: String
    var citedSources: [Int]
    var isAnswerFound: Bool
}

/// Understands questions and writes answers grounded in the user's notes.
protocol NoteAssistant: Sendable {
    func plan(question: String, history: [ChatTurn], now: Date) async throws -> AssistantPlan
    func answer(
        question: String,
        sources: [AssistantSource],
        history: [ChatTurn],
        language: TranscriptionLanguage,
        now: Date
    ) async throws -> AssistantAnswer
}

/// Uses Apple's on-device foundation model.
///
/// Both steps use guided generation (`@Generable`), so the output always has the expected
/// structure. The model never computes dates: it only names a time frame, which the app
/// converts with the calendar. Answers may only use the numbered sources and must cite
/// them; citations that do not refer to a source are removed.
struct FoundationModelNoteAssistant: NoteAssistant {
    func plan(question: String, history: [ChatTurn], now: Date) async throws -> AssistantPlan {
        let session = LanguageModelSession(instructions: """
        You prepare a search in the user's personal notes (transcripts of conversations, meetings \
        and lectures, and imported documents). Today is \(Self.dateText(now)).
        Extract what to search for. Keep the language of the question. Do not answer the question.
        """)
        var prompt = ""
        if !history.isEmpty {
            prompt += "Previous conversation:\n\(Self.historyText(history))\n\n"
        }
        prompt += "Question: \(question)"
        let response = try await session.respond(
            to: prompt,
            generating: GeneratedSearchPlan.self,
            options: GenerationOptions(temperature: 0.1, maximumResponseTokens: 300)
        )
        let generated = response.content
        return AssistantPlan(
            searchQuery: generated.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines),
            relatedTerms: generated.relatedTerms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            persons: generated.persons
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !TextAnalysis.isSpeakerLabel($0) },
            timeframe: Timeframe(rawValue: generated.timeframe) ?? .none,
            wantsList: generated.wantsList
        )
    }

    func answer(
        question: String,
        sources: [AssistantSource],
        history: [ChatTurn],
        language: TranscriptionLanguage,
        now: Date
    ) async throws -> AssistantAnswer {
        let languageName = Locale(identifier: "en").localizedString(forLanguageCode: language.languageCode) ?? "German"
        let session = LanguageModelSession(instructions: """
        You are the assistant of the note app NotifyAI. You answer questions about the user's own notes: \
        transcripts of conversations, meetings and lectures, and imported documents. Today is \(Self.dateText(now)).
        Rules:
        - Use only the numbered sources. Never add outside knowledge and never guess.
        - Put the source number after every statement, for example [2] or [1][3].
        - In transcripts, "Ich" is the user. Address the user as "du". Other labels are people in the conversation.
        - Every source has the date of its note. Relative dates in a source ("Freitag", "next week") refer to \
        that date; state the actual date when it matters.
        - Be concrete: names, numbers, amounts, dates and deadlines.
        - If the sources do not contain the answer, set answerFound to false and say so in one sentence.
        - Keep it short: one to five sentences, or a short list with "- " when there are several items.
        - Write in \(languageName).
        """)

        var prompt = ""
        if !history.isEmpty {
            prompt += "Previous conversation:\n\(Self.historyText(history))\n\n"
        }
        prompt += "Sources:\n"
        for source in sources {
            var header = "[\(source.number)] Note \"\(source.noteTitle)\" from \(Self.dateText(source.noteDate))"
            if let start = source.start {
                header += ", at minute \(TimeFormatting.timestamp(start))"
            }
            prompt += "\(header):\n\(source.text)\n\n"
        }
        prompt += "Question: \(question)"

        let response = try await session.respond(
            to: prompt,
            generating: GeneratedAnswer.self,
            options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 700)
        )
        let content = response.content
        return Self.validated(
            answer: content.answer,
            usedSources: content.usedSources,
            answerFound: content.answerFound,
            sourceCount: sources.count
        )
    }

    /// Removes citations of sources that do not exist and collects the cited numbers,
    /// in the order they appear in the text.
    static func validated(answer: String, usedSources: [Int], answerFound: Bool, sourceCount: Int) -> AssistantAnswer {
        let validRange = 1...max(sourceCount, 1)
        var text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        var cited: [Int] = []
        for match in text.matches(of: /\[(\d+)\]/).reversed() {
            if sourceCount > 0, let number = Int(match.1), validRange.contains(number) {
                cited.insert(number, at: 0)
            } else {
                text.removeSubrange(match.range)
            }
        }
        // Tidy the gaps removed citations leave ("Oktober ." → "Oktober.").
        text = text.replacing(/\ +([.,;:!?])/) { String($0.1) }
        text = text.replacing(/\ {2,}/, with: " ")
        var seen = Set<Int>()
        let valid = (cited + usedSources.filter { sourceCount > 0 && validRange.contains($0) }).filter { seen.insert($0).inserted }
        return AssistantAnswer(text: text, citedSources: valid, isAnswerFound: answerFound)
    }

    // MARK: Helpers

    private static func dateText(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .complete, time: .shortened).locale(Locale(identifier: "en_US")))
    }

    private static func historyText(_ history: [ChatTurn]) -> String {
        history.suffix(3).map { turn in
            "Q: \(turn.question)\nA: \(String(turn.answer.prefix(400)))"
        }.joined(separator: "\n")
    }
}

// MARK: - Structured output

@Generable(description: "How to search the user's notes for a question")
struct GeneratedSearchPlan {
    @Guide(description: "The essential content words of the question as a short search query, in the language of the question. Leave out time expressions, the names of people and filler words. Replace pronouns with what they refer to in the previous conversation.")
    var searchQuery: String

    @Guide(description: "Synonyms or closely related terms that could appear in the notes instead of the words in the question", .maximumCount(5))
    var relatedTerms: [String]

    @Guide(description: "People the question is about, as written in the question or the previous conversation. Empty if no person is mentioned.", .maximumCount(3))
    var persons: [String]

    @Guide(description: "The time frame the question refers to", .anyOf(["none", "today", "yesterday", "thisWeek", "lastWeek", "thisMonth", "lastMonth", "thisYear", "lastYear"]))
    var timeframe: String

    @Guide(description: "True only if the user asks for a list of notes or recordings, not for information from them")
    var wantsList: Bool
}

@Generable(description: "An answer that is based only on the numbered sources")
struct GeneratedAnswer {
    @Guide(description: "The answer with source numbers in square brackets after each statement")
    var answer: String

    @Guide(description: "Numbers of the sources the answer relies on", .maximumCount(8))
    var usedSources: [Int]

    @Guide(description: "False if the sources do not contain the information needed to answer the question")
    var answerFound: Bool
}
