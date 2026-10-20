//
//  SecretStore.swift
//  NotifyAIServices
//

import Foundation
import Security

/// Secrets of integrations (the Notion token, the webhook's signing secret) in the keychain,
/// available only on this device and only after it was unlocked once.
protocol SecretStoring: Sendable {
    func secret(for account: String) -> String?
    func setSecret(_ secret: String?, for account: String) throws
}

enum SecretStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            String(localized: "Der Zugangsschlüssel konnte nicht im Schlüsselbund gesichert werden (Fehler \(Int(status))).", bundle: .module)
        }
    }
}

struct KeychainSecretStore: SecretStoring {
    private let service = "com.justus.NotifyAI.integrations"

    func secret(for account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setSecret(_ secret: String?, for account: String) throws {
        let query = baseQuery(account)
        SecItemDelete(query as CFDictionary)
        guard let secret, !secret.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(secret.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // The data protection keychain on the Mac as well, like on iOS.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
