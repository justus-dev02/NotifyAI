//
//  AppLock.swift
//  NotifyAIServices
//

import Foundation
import LocalAuthentication
import Observation

/// Optional lock with Face ID / Touch ID / Optic ID and the device passcode as fallback.
@MainActor
@Observable
public final class AppLock {
    public private(set) var isLocked: Bool
    public private(set) var errorMessage: String?
    public private(set) var isAuthenticating = false

    @ObservationIgnored private let settings: PrivacySettings

    init(settings: PrivacySettings) {
        self.settings = settings
        self.isLocked = settings.appLockEnabled
    }

    /// Locks the app, e.g. when it moves to the background.
    public func lockIfEnabled() {
        if settings.appLockEnabled {
            isLocked = true
        }
    }

    public func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        let context = LAContext()
        var policyError: NSError?
        // `.deviceOwnerAuthentication` falls back to the passcode. The former
        // implementation unlocked without any check when biometrics were unavailable.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            errorMessage = String(localized: "Auf diesem Gerät ist kein Code und keine biometrische Anmeldung eingerichtet.", bundle: .module)
            return
        }
        do {
            try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: String(localized: "Entsperre NotifyAI, um auf deine Notizen zuzugreifen.", bundle: .module)
            )
            isLocked = false
            errorMessage = nil
        } catch let error as LAError where error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel {
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "Die Entsperrung ist fehlgeschlagen.", bundle: .module)
        }
    }

    /// Called when the setting is switched off so the app does not stay locked.
    public func disable() {
        isLocked = false
        errorMessage = nil
    }

    /// The biometry type for labels and icons.
    public static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return switch context.biometryType {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        default: String(localized: "Gerätecode", bundle: .module)
        }
    }
}
