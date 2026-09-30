//
//  WhisperModel.swift
//  NotifyAI
//

import Foundation

/// A Whisper model variant from the `argmaxinc/whisperkit-coreml` repository.
struct WhisperModel: Identifiable, Hashable, Codable, Sendable {
    /// Folder name of the variant in the model repository.
    let id: String
    let name: String
    let detail: String
    let approximateSize: String

    static let base = WhisperModel(
        id: "openai_whisper-base",
        name: "Base",
        detail: String(localized: "Sehr schnell, für klare Sprache in ruhiger Umgebung."),
        approximateSize: String(localized: "ca. 150 MB")
    )

    static let small = WhisperModel(
        id: "openai_whisper-small",
        name: "Small",
        detail: String(localized: "Guter Kompromiss aus Genauigkeit und Geschwindigkeit auf dem iPhone."),
        approximateSize: String(localized: "ca. 500 MB")
    )

    static let largeTurbo = WhisperModel(
        id: "openai_whisper-large-v3-v20240930_turbo_632MB",
        name: "Large v3 Turbo",
        detail: String(localized: "Höchste Genauigkeit. Empfohlen für Mac und neuere iPhones (Pro-Modelle)."),
        approximateSize: String(localized: "ca. 630 MB")
    )

    static let all: [WhisperModel] = [base, small, largeTurbo]

    static var recommended: WhisperModel {
        #if os(macOS)
        .largeTurbo
        #else
        .small
        #endif
    }

    static func withID(_ id: String) -> WhisperModel? {
        all.first { $0.id == id }
    }
}
