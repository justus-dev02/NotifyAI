//
//  WhisperModel.swift
//  NotifyAIServices
//

import Foundation

/// A Whisper model variant from the `argmaxinc/whisperkit-coreml` repository.
public struct WhisperModel: Identifiable, Hashable, Codable, Sendable {
    /// Folder name of the variant in the model repository.
    public let id: String
    public let name: String
    public let detail: String
    public let approximateSize: String

    static let base = Self(
        id: "openai_whisper-base",
        name: "Base",
        detail: String(localized: "Sehr schnell, für klare Sprache in ruhiger Umgebung.", bundle: .module),
        approximateSize: String(localized: "ca. 150 MB", bundle: .module)
    )

    static let small = Self(
        id: "openai_whisper-small",
        name: "Small",
        detail: String(localized: "Guter Kompromiss aus Genauigkeit und Geschwindigkeit auf dem iPhone.", bundle: .module),
        approximateSize: String(localized: "ca. 500 MB", bundle: .module)
    )

    static let largeTurbo = Self(
        id: "openai_whisper-large-v3-v20240930_turbo_632MB",
        name: "Large v3 Turbo",
        detail: String(localized: "Höchste Genauigkeit. Empfohlen für Mac und neuere iPhones (Pro-Modelle).", bundle: .module),
        approximateSize: String(localized: "ca. 630 MB", bundle: .module)
    )

    public static let all: [Self] = [base, small, largeTurbo]

    /// The Mac has the memory and the Neural Engine time for the largest model.
    public static var recommended: Self {
        DeviceProfile.build == .mac ? .largeTurbo : .small
    }

    static func withID(_ id: String) -> Self? {
        all.first { $0.id == id }
    }
}
