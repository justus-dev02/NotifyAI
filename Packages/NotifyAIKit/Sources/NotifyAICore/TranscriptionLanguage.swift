//
//  TranscriptionLanguage.swift
//  NotifyAICore
//

import Foundation

/// A spoken language that can be transcribed and summarized.
///
/// The identifier is a BCP 47 locale identifier (for example `de-DE`), which is what
/// Apple's speech framework expects. Whisper only needs the ISO 639-1 language code.
public struct TranscriptionLanguage: Hashable, Identifiable, Codable, Sendable {
    public let id: String

    public var locale: Locale { Locale(identifier: id) }

    /// ISO 639-1 code (`de`, `en`, …) as used by Whisper.
    public var languageCode: String { locale.language.languageCode?.identifier ?? "en" }

    public var displayName: String {
        Locale.current.localizedString(forIdentifier: id) ?? id
    }

    public static let german = Self(id: "de-DE")
    public static let englishUS = Self(id: "en-US")
    public static let englishUK = Self(id: "en-GB")
    public static let french = Self(id: "fr-FR")
    public static let spanish = Self(id: "es-ES")
    public static let italian = Self(id: "it-IT")

    /// Languages offered in the UI. Both transcription engines and the on-device
    /// language model support all of them.
    public static let all: [Self] = [german, englishUS, englishUK, french, spanish, italian]

    public init(id: String) {
        self.id = id
    }
}
