//
//  TranscriptionLanguage.swift
//  NotifyAI
//

import Foundation

/// A spoken language that can be transcribed and summarized.
///
/// The identifier is a BCP 47 locale identifier (for example `de-DE`), which is what
/// Apple's speech framework expects. Whisper only needs the ISO 639-1 language code.
struct TranscriptionLanguage: Hashable, Identifiable, Codable, Sendable {
    let id: String

    var locale: Locale { Locale(identifier: id) }

    /// ISO 639-1 code (`de`, `en`, …) as used by Whisper.
    var languageCode: String { locale.language.languageCode?.identifier ?? "en" }

    var displayName: String {
        Locale.current.localizedString(forIdentifier: id) ?? id
    }

    static let german = TranscriptionLanguage(id: "de-DE")
    static let englishUS = TranscriptionLanguage(id: "en-US")
    static let englishUK = TranscriptionLanguage(id: "en-GB")
    static let french = TranscriptionLanguage(id: "fr-FR")
    static let spanish = TranscriptionLanguage(id: "es-ES")
    static let italian = TranscriptionLanguage(id: "it-IT")

    /// Languages offered in the UI. Both transcription engines and the on-device
    /// language model support all of them.
    static let all: [TranscriptionLanguage] = [german, englishUS, englishUK, french, spanish, italian]
}
