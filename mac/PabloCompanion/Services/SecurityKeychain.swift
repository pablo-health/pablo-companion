import CompanionSessionCore
import Foundation
import os
import Security

/// The real macOS Keychain, behind `KeychainStoring`.
///
/// This is the only type in the app that talks to Security.framework, which is
/// what lets everything above it be tested with a fake — and what would let the
/// encryptor eventually move into `CompanionSessionCore`, since the Keychain is
/// its last macOS-only dependency.
struct SecurityKeychain: KeychainStoring {
    private static let logger = Logger(
        subsystem: AppConstants.appBundleID, category: "SecurityKeychain"
    )

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConstants.appBundleID,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: AppConstants.keychainAccessGroup,
        ]
    }

    func string(forKey key: String) -> String? {
        // Failable rather than String(decoding:as:): a stored credential that is
        // not valid UTF-8 is corrupt, and should read as absent rather than as a
        // string full of replacement characters.
        data(forKey: key).flatMap { String(bytes: $0, encoding: .utf8) }
    }

    func setString(_ value: String, forKey key: String) {
        setData(Data(value.utf8), forKey: key)
    }

    func data(forKey key: String) -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    func setData(_ value: Data, forKey key: String) {
        let query = baseQuery(key)
        // Update first, add if absent — an add over an existing item fails with
        // errSecDuplicateItem rather than replacing it.
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard updateStatus == errSecItemNotFound else {
            if updateStatus != errSecSuccess {
                Self.logger.error("Keychain update failed for \(key): \(updateStatus)")
            }
            return
        }

        var addQuery = query
        addQuery[kSecValueData as String] = value
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            Self.logger.error("Keychain save failed for \(key): \(addStatus)")
        }
    }

    func removeItem(forKey key: String) {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            Self.logger.error("Keychain delete failed for \(key): \(status)")
        }
    }
}
