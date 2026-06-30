import Foundation
import Security

/// Cross-platform Keychain wrapper for sensitive provider secrets (API keys).
///
/// Stores generic-password items under a single service, keyed by an `account`
/// string (we use `Provider.id.uuidString`). Pure Foundation + Security, so it
/// is reusable as-is on iOS inside the shared Core.
enum KeychainStore {
    /// Service namespace for all houmao API-key items.
    private static let service = "cn.com.houmao.houmao.apikeys"

    /// Upsert a secret for `account`. An empty value deletes the item, so the
    /// Keychain never holds stale empty secrets.
    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Idempotent upsert: delete any existing item, then re-add.
        SecItemDelete(base as CFDictionary)

        guard !value.isEmpty else { return }

        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            // Non-fatal: the in-memory value still works for the session.
            NSLog("KeychainStore.set failed for \(account): OSStatus \(status)")
        }
    }

    /// Read the secret for `account`, or nil if absent.
    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    /// Delete the secret for `account` (no-op if it doesn't exist).
    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
