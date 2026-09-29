//
//  GeneralSettings.swift
//  NotifyAI
//

import Foundation
import Observation

/// Where the Mac app appears.
enum AppPresence: String, CaseIterable, Identifiable, Sendable {
    case dock
    case dockAndMenuBar
    case menuBar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dock: "Nur im Dock"
        case .dockAndMenuBar: "Im Dock und in der Menüleiste"
        case .menuBar: "Nur in der Menüleiste"
        }
    }

    var showsDockIcon: Bool { self != .menuBar }
    var showsMenuBarItem: Bool { self != .dock }
}

/// App-wide state: onboarding and, on the Mac, Dock and menu bar presence.
@MainActor
@Observable
final class GeneralSettings {
    private enum Key {
        static let appPresence = "app.presence"
        static let onboardingCompleted = "app.onboardingCompleted"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Where the Mac app appears: Dock, menu bar or both.
    var appPresence: AppPresence {
        didSet { defaults.set(appPresence.rawValue, forKey: Key.appPresence) }
    }

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.onboardingCompleted) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        appPresence = Self.storedAppPresence(defaults: defaults)
        hasCompletedOnboarding = defaults.bool(forKey: Key.onboardingCompleted)
    }

    /// The stored presence, readable before the settings exist (at app launch).
    nonisolated static func storedAppPresence(defaults: UserDefaults = .standard) -> AppPresence {
        defaults.string(forKey: Key.appPresence).flatMap(AppPresence.init(rawValue:)) ?? .dockAndMenuBar
    }
}
