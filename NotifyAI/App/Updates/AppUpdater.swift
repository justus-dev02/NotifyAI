//
//  AppUpdater.swift
//  NotifyAI
//

#if os(macOS)
import Foundation
import NotifyAICore
import OSLog
import Sparkle

/// Something that can ask for background update checks to wait, e.g. a running recording.
@MainActor
protocol UpdateDeferring: AnyObject {
    /// While `true`, background checks are skipped so no update window interrupts the work.
    var defersUpdates: Bool { get }
}

@MainActor
@Observable
final class AppUpdater: NSObject {

    let isConfigured: Bool
    /// `false` while a check, download or installation is already in progress.
    private(set) var canCheckForUpdates = false
    private(set) var lastUpdateCheckDate: Date?

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    /// Background checks are skipped while it defers them, so no update window interrupts
    /// a recording. Manual checks always run.
    @ObservationIgnored private weak var deferral: (any UpdateDeferring)?
    private static let log = Logger(subsystem: Logger.subsystem, category: "Updates")

    init(deferral: any UpdateDeferring) {
        self.deferral = deferral
        isConfigured = Self.hasInfoValue("SUFeedURL") && Self.hasInfoValue("SUPublicEDKey")
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        guard isConfigured else {
            Self.log.notice("Updates disabled: SUFeedURL or SUPublicEDKey missing in Info.plist")
            return
        }
        controller.startUpdater()
        // Sparkle changes this property on the main thread only.
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
        lastUpdateCheckDate = updater.lastUpdateCheckDate
    }

    private var updater: SPUUpdater { controller.updater }

    /// Checks now and shows the result, including "NotifyAI ist aktuell".
    func checkForUpdates() {
        guard isConfigured else { return }
        controller.checkForUpdates(nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return isConfigured && updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get {
            access(keyPath: \.automaticallyDownloadsUpdates)
            return isConfigured && updater.automaticallyDownloadsUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyDownloadsUpdates) {
                updater.automaticallyDownloadsUpdates = newValue
            }
        }
    }

    var checkInterval: UpdateCheckInterval {
        get {
            access(keyPath: \.checkInterval)
            return UpdateCheckInterval(seconds: updater.updateCheckInterval)
        }
        set {
            withMutation(keyPath: \.checkInterval) {
                updater.updateCheckInterval = newValue.seconds
            }
        }
    }

    private static func hasInfoValue(_ key: String) -> Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return false }
        return !value.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updatesInBackground, deferral?.defersUpdates == true else { return }
        throw NSError(domain: "NotifyAI.AppUpdater", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Background update check postponed during a recording",
        ])
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        lastUpdateCheckDate = updater.lastUpdateCheckDate
        if let error {
            Self.log.notice("Update cycle finished with error: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension AppUpdater: SPUStandardUserDriverDelegate {
    /// In "menu bar only" mode the app has no Dock icon; gentle reminders let Sparkle show
    /// a scheduled update without stealing focus from the app the user is working in.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}

/// How often Sparkle looks for a new version in the background.
enum UpdateCheckInterval: CaseIterable, Identifiable {
    case daily, weekly, monthly

    var id: Self { self }

    var seconds: TimeInterval {
        switch self {
        case .daily: 86_400
        case .weekly: 604_800
        case .monthly: 2_629_800
        }
    }

    /// Maps Sparkle's stored interval to the nearest option.
    init(seconds: TimeInterval) {
        self = Self.allCases.min { abs($0.seconds - seconds) < abs($1.seconds - seconds) } ?? .daily
    }

    var title: String {
        switch self {
        case .daily: String(localized: "Täglich")
        case .weekly: String(localized: "Wöchentlich")
        case .monthly: String(localized: "Monatlich")
        }
    }
}
#endif
