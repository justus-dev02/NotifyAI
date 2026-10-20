//
//  TaskQualityTests.swift
//  NotifyAITests
//
//  Which tasks a summary keeps: concrete ones the text supports, with their owner, deadline
//  and position; vague, invented, hedged and duplicate ones are left out.
//

import Foundation
@testable import NotifyAI
import NotifyAICore
@testable import NotifyAIServices
import Testing

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    return calendar
}()

/// Wednesday, 30 September 2026.
private let recordedAt = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 10))!

private let meeting = [
    TranscriptSegment(start: 0, end: 4, text: "Guten Morgen zusammen, heute geht es um den Relaunch.", speaker: "Anna Schmidt"),
    TranscriptSegment(start: 5, end: 9, text: "Ich schicke Frau Berger das überarbeitete Angebot bis Freitag.", speaker: "Ich"),
    TranscriptSegment(start: 10, end: 14, text: "Dann kümmere ich mich um die Texte für die Startseite.", speaker: "Eddy"),
    TranscriptSegment(start: 15, end: 19, text: "Wir sollten auch mal über die nächsten Schritte reden.", speaker: "Anna Schmidt"),
    TranscriptSegment(start: 20, end: 24, text: "Anna, prüfst du bitte das Budget für den Relaunch?", speaker: "Eddy"),
]

@Suite("Refining tasks")
struct ActionItemRefinerTests {
    let refiner = ActionItemRefiner(
        text: Transcript.plainText(of: meeting),
        segments: meeting,
        languageCode: "de",
        people: ["Anna Schmidt", "Ich", "Eddy"],
        recordedAt: recordedAt
    )

    @Test("Concrete, supported tasks stay with owner, deadline and position; the rest goes")
    func refine() {
        let items = [
            ActionItem(task: "- Aufgabe: überarbeitetes Angebot an Frau Berger schicken.", owner: "ich", evidence: "Ich schicke Frau Berger das überarbeitete Angebot bis Freitag."),
            // The same task again, in other words.
            ActionItem(task: "Angebot an Frau Berger schicken", owner: nil),
            // "Ich" in Eddy's line is Eddy.
            ActionItem(task: "Texte für die Startseite schreiben", owner: "Ich", evidence: "Dann kümmere ich mich um die Texte für die Startseite."),
            // Vague: only generic words.
            ActionItem(task: "Nächste Schritte besprechen", owner: "wir"),
            // Nothing in the text supports it.
            ActionItem(task: "Logo für die Messe drucken lassen", owner: "Anna"),
            // A first name becomes the participant's full name; "nicht angegeben" is no deadline.
            ActionItem(task: "Budget für den Relaunch prüfen", owner: "anna", due: "nicht angegeben"),
        ]

        let result = refiner.refine(items)

        #expect(result.items.map(\.task) == [
            "Überarbeitetes Angebot an Frau Berger schicken",
            "Texte für die Startseite schreiben",
            "Budget für den Relaunch prüfen",
        ])
        #expect(result.items.map(\.owner) == ["Ich", "Eddy", "Anna Schmidt"])
        #expect(result.items.map(\.due) == ["Freitag", nil, nil])
        #expect(result.sourceTimes["Überarbeitetes Angebot an Frau Berger schicken"] == 5)
        #expect(result.sourceTimes["Texte für die Startseite schreiben"] == 10)
        #expect(result.sourceTimes["Budget für den Relaunch prüfen"] == 20)
    }

    @Test("Owners: pronouns of nobody in particular are dropped, unknown names kept")
    func owners() {
        #expect(refiner.owner("wir", speaker: "Eddy") == nil)
        #expect(refiner.owner("du", speaker: nil) == nil)
        #expect(refiner.owner("Ich", speaker: nil) == "Ich")
        #expect(refiner.owner("ich", speaker: "Eddy") == "Eddy")
        #expect(refiner.owner("Frau Berger", speaker: "Eddy") == "Frau Berger")
        #expect(refiner.owner("k. A.", speaker: nil) == nil)
    }

    @Test("Task texts lose list markers and labels")
    func cleaning() {
        #expect(ActionItemRefiner.cleanedTask("1. Todo: budget prüfen;") == "Budget prüfen")
        #expect(ActionItemRefiner.cleanedTask("• Action item: send the deck.") == "Send the deck")
        #expect(ActionItemRefiner.cleanedTask(" - ") == nil)
        #expect(ActionItemRefiner.withoutDeadlineWord("bis Freitag") == "Freitag")
        #expect(ActionItemRefiner.withoutDeadlineWord("Freitag") == "Freitag")
    }

    @Test("Deadlines said in the sentence; greetings are none")
    func deadlines() {
        #expect(DeadlinePhrase.phrase(in: "Ich schicke es bis zum 3. Oktober.", relativeTo: recordedAt) == "zum 3. Oktober")
        #expect(DeadlinePhrase.phrase(in: "Das mache ich bis nächste Woche.", relativeTo: recordedAt) == "nächste Woche")
        #expect(DeadlinePhrase.phrase(in: "Ich schicke es dir morgen.", relativeTo: recordedAt) == "morgen")
        #expect(DeadlinePhrase.phrase(in: "I'll send it by Friday.", relativeTo: recordedAt) == "Friday")
        #expect(DeadlinePhrase.phrase(in: "Guten Morgen, ich schicke es dir.", relativeTo: recordedAt) == nil)
        #expect(DeadlinePhrase.phrase(in: "Heute Morgen habe ich angerufen.", relativeTo: recordedAt) == nil)
        #expect(DeadlinePhrase.phrase(in: "Ich rufe sie bis 3 Uhr an.", relativeTo: recordedAt) == nil)
    }

    @Test("Without speakers, documents are checked sentence by sentence")
    func document() {
        let refiner = ActionItemRefiner(
            text: "Protokoll. Herr Wolf liefert die Zahlen bis Montag. Sonst nichts.",
            segments: [],
            languageCode: "de",
            people: [],
            recordedAt: recordedAt
        )
        let result = refiner.refine([ActionItem(task: "Zahlen liefern", owner: "Herr Wolf"), ActionItem(task: "Kaffee kaufen")])
        #expect(result.items.map(\.task) == ["Zahlen liefern"])
        #expect(result.items.first?.due == "Montag")
        #expect(result.sourceTimes.isEmpty)
    }
}

@Suite("Tasks without Apple Intelligence")
struct ExtractiveTaskTests {
    @Test("Commitments belong to their speaker; ideas, hedges and finished things are no tasks")
    func commitments() async throws {
        let text = """
        Anna: Vielleicht könnten wir das Logo ändern. Ich schicke das Angebot bis Freitag an Frau Berger.
        Eddy: Das Angebot habe ich schon verschickt. Also, ich kümmere mich um die Texte für die Startseite.
        Anna: Gut, dann machen wir das so.
        """
        let request = SummaryRequest(text: text, language: .german, focus: .meeting, kind: .recording, markedPassages: [])
        let summary = try await ExtractiveSummarizer().summarize(request) { _ in }

        #expect(summary.actionItems.count == 2)
        let offer = try #require(summary.actionItems.first)
        #expect(offer.task.hasPrefix("Ich schicke das Angebot bis Freitag an Frau Berger"))
        #expect(offer.owner == "Anna")
        let texts = try #require(summary.actionItems.last)
        // The filler at the start is gone.
        #expect(texts.task.hasPrefix("Ich kümmere mich um die Texte"))
        #expect(texts.owner == "Eddy")
        #expect(!summary.actionItems.contains { $0.task.contains("Logo") || $0.task.contains("verschickt") })
    }

    @Test("Sentences keep the speaker of their line")
    func speakers() {
        let sentences = ExtractiveSummarizer.sentences(in: "Anna: Erster Satz. Zweiter Satz.\nOhne Sprecher geht es auch.")
        #expect(sentences.map(\.speaker) == ["Anna", "Anna", nil])
        #expect(sentences.first?.text == "Erster Satz.")
    }
}

@Suite("Task prompt")
struct TaskPromptTests {
    @Test("The model is told what a task is and quotes where it was agreed")
    func instructions() async throws {
        let responder = TemplateResponder()
        let summarizer = FoundationModelSummarizer(responder: responder, measure: TextChunker.estimatedTokens)
        let request = SummaryRequest(
            text: "Anna schickt das Angebot an den Kunden. Der Kunde wünscht einen Relaunch der Website.",
            language: .german,
            focus: .meeting,
            kind: .recording,
            markedPassages: []
        )
        _ = try await summarizer.summarize(request) { _ in }
        let instructions = try #require(responder.instructions.first)
        #expect(instructions.contains("hypothetical or conditional"))
        #expect(instructions.contains("starts with a verb"))
        #expect(instructions.contains("List each task once"))

        let notes = FoundationModelSummarizer.notesText(
            keyPoints: [],
            decisions: [],
            actionItems: [ActionItem(task: "Angebot schicken", owner: "Anna", evidence: String(repeating: "x", count: 300))],
            openQuestions: []
        )
        #expect(notes.hasPrefix("Task: Angebot schicken (owner: Anna) (quote: \"xxx"))
        #expect(notes.count < 300)
    }
}
