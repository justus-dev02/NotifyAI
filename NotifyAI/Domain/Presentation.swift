//
//  Presentation.swift
//  NotifyAI
//
//  User-facing names of the core types. They live in the app, next to its string catalog;
//  NotifyAICore stays free of presentation.
//

import Foundation
import NotifyAICore

extension NoteKind {
    var displayName: String {
        switch self {
        case .recording: String(localized: "Aufnahme")
        case .audioImport: String(localized: "Audiodatei")
        case .document: String(localized: "PDF")
        case .image: String(localized: "Bild")
        }
    }
}

extension NoteStatus {
    var displayName: String {
        switch self {
        case .recording: String(localized: "Aufnahme läuft")
        case .queued: String(localized: "In Warteschlange")
        case .transcribing: String(localized: "Wird transkribiert")
        case .identifyingSpeakers: String(localized: "Sprecher werden erkannt")
        case .summarizing: String(localized: "Wird zusammengefasst")
        case .ready: String(localized: "Fertig")
        case .failed: String(localized: "Fehlgeschlagen")
        }
    }
}

extension RecordingFocus {
    var title: String {
        switch self {
        case .general: String(localized: "Allgemein")
        case .meeting: String(localized: "Meeting")
        case .lecture: String(localized: "Vorlesung")
        case .interview: String(localized: "Interview")
        case .sales: String(localized: "Kundengespräch")
        case .oneOnOne: String(localized: "1:1-Gespräch")
        }
    }
}
