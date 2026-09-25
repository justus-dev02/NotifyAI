//
//  AppLock.swift
//  NotifyAI
//

import Foundation
import LocalAuthentication
import Observation

/// Optional lock with Face ID / Touch ID / Optic ID and the device passcode as fallback.
@MainActor
@Observable
final class AppLock {
    private(set) var isLocked: Bool
    private(set) var errorMessage: String?
    private(set) var isAuthenticating = false

    @ObservationIgnored private let isEnabled: @MainActor () -> Bool

    init(isEnabled: @escaping @MainActor () -> Bool) {
        self.isEnabled = isEnabled
        self.isLocked = isEnabled()
    }

    /// Locks the app, e.g. when it moves to the background.
    func lockIfEnabled() {
        if isEnabled() {
            isLocked = true
        }
    }

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        let context = LAContext()
        var policyError: NSError?
        // `.deviceOwnerAuthentication` falls back to the passcode. The former
        // implementation unlocked without any check when biometrics were unavailable.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            errorMessage = "Auf diesem Gerät ist kein Code und keine biometrische Anmeldung eingerichtet."
            return
        }
        do {
            try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Entsperre NotifyAI, um auf deine Notizen zuzugreifen."
            )
            isLocked = false
            errorMessage = nil
        } catch let error as LAError where error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel {
            errorMessage = nil
        } catch {
            errorMessage = "Die Entsperrung ist fehlgeschlagen."
        }
    }

    /// Called when the setting is switched off so the app does not stay locked.
    func disable() {
        isLocked = false
        errorMessage = nil
    }

    /// The biometry type for labels and icons.
    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return switch context.biometryType {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        default: "Gerätecode"
        }
    }
}
