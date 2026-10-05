//
//  DomainNames.swift
//  NotifyAIServices
//
//  User-facing names of the core types. NotifyAICore stays free of presentation; the names
//  live here, next to this module's string catalog, because services need them too
//  (automatic titles, exports, background task titles) and the app shows them.
//

import Foundation
import NotifyAICore
import NotifyAIPersistence

extension NoteKind {
    public var displayName: String {
        switch self {
        case .recording: String(localized: "Aufnahme", bundle: .module)
        case .audioImport: String(localized: "Audiodatei", bundle: .module)
        case .document: String(localized: "PDF", bundle: .module)
        case .image: String(localized: "Bild", bundle: .module)
        }
    }
}

extension NoteStatus {
    public var displayName: String {
        switch self {
        case .recording: String(localized: "Aufnahme läuft", bundle: .module)
        case .queued: String(localized: "In Warteschlange", bundle: .module)
        case .transcribing: String(localized: "Wird transkribiert", bundle: .module)
        case .identifyingSpeakers: String(localized: "Sprecher werden erkannt", bundle: .module)
        case .summarizing: String(localized: "Wird zusammengefasst", bundle: .module)
        case .ready: String(localized: "Fertig", bundle: .module)
        case .failed: String(localized: "Fehlgeschlagen", bundle: .module)
        }
    }
}

extension RecordingFocus {
    public var title: String {
        switch self {
        case .general: String(localized: "Allgemein", bundle: .module)
        case .meeting: String(localized: "Meeting", bundle: .module)
        case .lecture: String(localized: "Vorlesung", bundle: .module)
        case .interview: String(localized: "Interview", bundle: .module)
        case .sales: String(localized: "Kundengespräch", bundle: .module)
        case .oneOnOne: String(localized: "1:1-Gespräch", bundle: .module)
        }
    }
}

extension RecordingAudioSource {
    public var title: String {
        switch self {
        case .microphone: String(localized: "Mikrofon", bundle: .module)
        case .microphoneAndSystemAudio: String(localized: "Mikrofon + Systemton", bundle: .module)
        case .systemAudio: String(localized: "Nur Systemton", bundle: .module)
        }
    }

    public var detail: String {
        switch self {
        case .microphone:
            String(localized: "Nimmt auf, was im Raum gesprochen wird.", bundle: .module)
        case .microphoneAndSystemAudio:
            String(localized: "Für Online-Meetings: deine Stimme über das Mikrofon, die anderen Teilnehmenden direkt aus der App (z. B. Zoom, Teams, Discord).", bundle: .module)
        case .systemAudio:
            String(localized: "Nimmt nur den Ton von Apps auf, z. B. Webinare oder Videos. Das Mikrofon bleibt aus.", bundle: .module)
        }
    }
}

extension SystemAudioTarget {
    public var displayName: String {
        switch self {
        case .allApps: String(localized: "Alle Apps", bundle: .module)
        case .app(_, let name): name
        }
    }
}

extension TranscriptionEngineKind {
    public var summary: String {
        switch self {
        case .appleSpeech:
            String(localized: "Schnell und sparsam. Der Text erscheint live, das Sprachpaket stellt das System bereit.", bundle: .module)
        case .whisper:
            String(localized: "Sehr genau, auch bei Fachbegriffen. Benötigt ein einmal geladenes Modell; live erscheint der Text abschnittsweise.", bundle: .module)
        }
    }
}

extension Note {
    /// "Mikrofon + Zoom", "Systemton · Alle Apps" …; `nil` for microphone recordings.
    public var audioSourceDescription: String? {
        let app = sourceAppName ?? SystemAudioTarget.allApps.displayName
        return switch audioSource {
        case .microphone: nil
        case .microphoneAndSystemAudio:
            sourceAppName.map { String(localized: "Mikrofon + \($0)", bundle: .module) } ?? RecordingAudioSource.microphoneAndSystemAudio.title
        case .systemAudio: String(localized: "Systemton · \(app)", bundle: .module)
        }
    }
}
