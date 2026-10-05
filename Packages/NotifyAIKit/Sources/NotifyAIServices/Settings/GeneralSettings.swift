//
//  GeneralSettings.swift
//  NotifyAIServices
//

import Foundation
import Observation

/// Where the Mac app appears.
public enum AppPresence: String, CaseIterable, Identifiable, Sendable {
    case dock
    case dockAndMenuBar
    case menuBar

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dock: String(localized: "Nur im Dock", bundle: .module)
        case .dockAndMenuBar: String(localized: "Im Dock und in der Menüleiste", bundle: .module)
        case .menuBar: String(localized: "Nur in der Menüleiste", bundle: .module)
        }
    }

    public var showsDockIcon: Bool { self != .menuBar }
    public var showsMenuBarItem: Bool { self != .dock }
}

/// App-wide state: onboarding and, on the Mac, Dock and menu bar presence.
@MainActor
@Observable
public final class GeneralSettings {
    private enum Key {
        static let appPresence = "app.presence"
        static let onboardingCompleted = "app.onboardingCompleted"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Where the Mac app appears: Dock, menu bar or both.
    public var appPresence: AppPresence {
        didSet { defaults.set(appPresence.rawValue, forKey: Key.appPresence) }
    }

    public var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.onboardingCompleted) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        appPresence = Self.storedAppPresence(defaults: defaults)
        hasCompletedOnboarding = defaults.bool(forKey: Key.onboardingCompleted)
    }

    /// The stored presence, readable before the settings exist (at app launch).
    nonisolated public static func storedAppPresence(defaults: UserDefaults = .standard) -> AppPresence {
        defaults.string(forKey: Key.appPresence).flatMap(AppPresence.init(rawValue:)) ?? .dockAndMenuBar
    }
}
