//
//  UITestSampleData.swift
//  NotifyAI
//

#if DEBUG
import Foundation
import NotifyAICore

/// Notes with summaries and tasks for the UI tests (`-ui-testing-sample-data`). Only in
/// debug builds; the released app never contains them.
@MainActor
enum UITestSampleData {
    static let argument = "-ui-testing-sample-data"

    static func insert(into store: NoteStore, now: Date = .now) throws {
        let weekly = Note(title: "Weekly Marketing", isTitleUserDefined: true, createdAt: now, kind: .document, status: .ready,
                          participants: ["Anna", "Ben"], bodyText: "Anna erstellt die Präsentation bis Freitag. Ben prüft das Budget.")
        weekly.summary = NoteSummary(
            overview: "Planung der Herbstkampagne.",
            keyPoints: ["Die Kampagne startet im Oktober."],
            actionItems: [
                ActionItem(task: "Präsentation erstellen", owner: "Anna", due: "heute"),
                ActionItem(task: "Budget prüfen", owner: "Ben", due: "nächste Woche"),
            ],
            source: .extractive
        )
        let review = Note(title: "Projekt-Review", isTitleUserDefined: true, createdAt: now.addingTimeInterval(-86_400), kind: .document,
                          status: .ready, bodyText: "Die Dokumentation muss aktualisiert werden.")
        review.summary = NoteSummary(
            overview: "Rückblick auf das Projekt.",
            actionItems: [ActionItem(task: "Dokumentation aktualisieren")],
            source: .extractive
        )
        try store.insert(weekly)
        try store.insert(review)
    }
}
#endif
