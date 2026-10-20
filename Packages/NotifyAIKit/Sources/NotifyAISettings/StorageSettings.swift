//
//  StorageSettings.swift
//  NotifyAISettings
//

import Foundation
import NotifyAISupport
import Observation

/// How long recordings keep their audio. Text, summary and tasks always stay.
public enum AudioRetention: String, CaseIterable, Identifiable, Sendable {
    case forever
    case thirtyDays
    case ninetyDays
    case oneYear

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .forever: String(localized: "Immer behalten", bundle: .module)
        case .thirtyDays: String(localized: "Nach 30 Tagen löschen", bundle: .module)
        case .ninetyDays: String(localized: "Nach 90 Tagen löschen", bundle: .module)
        case .oneYear: String(localized: "Nach einem Jahr löschen", bundle: .module)
        }
    }

    /// Recordings made before this moment lose their audio; `nil` keeps every recording.
    public func cutoff(now: Date = .now, calendar: Calendar = .current) -> Date? {
        let days = switch self {
        case .forever: 0
        case .thirtyDays: 30
        case .ninetyDays: 90
        case .oneYear: 365
        }
        guard days > 0 else { return nil }
        return calendar.date(byAdding: .day, value: -days, to: now)
    }
}

/// What the app keeps on the device.
@MainActor
@Observable
public final class StorageSettings {
    private enum Key {
        static let audioRetention = "storage.audioRetention"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Deletes the audio of older recordings automatically, favorites excepted.
    public var audioRetention: AudioRetention {
        didSet { defaults.set(audioRetention.rawValue, forKey: Key.audioRetention) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        audioRetention = defaults.string(forKey: Key.audioRetention).flatMap(AudioRetention.init(rawValue:)) ?? .forever
    }
}
