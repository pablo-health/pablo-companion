import Foundation
import os
import Security

/// Provides CRUD access to the macOS Keychain for auth tokens.
struct KeychainManager: Sendable {
    enum TokenKey: String, Sendable {
        case idToken = "id_token"
        case refreshToken = "refresh_token"
        case userEmail = "user_email"
        case authServerURL = "auth_server_url"
        case firebaseAPIKey = "firebase_api_key"
        case backendAPIURL = "backend_api_url"
        case tenantID = "tenant_id"
        case tokenExpiry = "token_expiry"
    }

    private static let serviceName = AppConstants.appBundleID
    private static let accessGroup = AppConstants.keychainAccessGroup
    private static let logger = Logger(subsystem: AppConstants.appBundleID, category: "KeychainManager")

    static func saveToken(_ value: String, forKey key: TokenKey) {
        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrAccessGroup as String: accessGroup,
        ]

        // Try updating first; add if not found.
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                logger.error("Keychain save failed for \(key.rawValue): \(addStatus)")
            }
        } else if updateStatus != errSecSuccess {
            logger.error("Keychain update failed for \(key.rawValue): \(updateStatus)")
        }
    }

    static func getToken(forKey key: TokenKey) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func deleteToken(forKey key: TokenKey) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrAccessGroup as String: accessGroup,
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            logger.error("Keychain delete failed for \(key.rawValue): \(status)")
        }
    }

    /// Deletes auth tokens only. Encryption keys are preserved so pending uploads
    /// can still be retried after the next sign-in.
    static func deleteAuthTokens() {
        for key in [
            TokenKey.idToken,
            .refreshToken,
            .userEmail,
            .authServerURL,
            .firebaseAPIKey,
            .backendAPIURL,
            .tenantID,
            .tokenExpiry,
        ] {
            deleteToken(forKey: key)
        }
    }

    /// Deletes auth tokens AND the encryption key for the given user.
    /// Call only for explicit "purge local data" — not on regular sign-out.
    static func purgeAllData(forUser email: String) {
        deleteAuthTokens()
        deleteEncryptionKey(forUser: email)
        // Also remove any legacy device-wide key
        deleteEncryptionKey(account: legacyDeviceKeyAccount)
    }

    // MARK: - Per-User Encryption Key

    private static let legacyDeviceKeyAccount = "device_encryption_key"

    private static func encryptionKeyAccount(forUser email: String) -> String {
        "device_encryption_key_\(email)"
    }

    /// Returns the encryption key for the given user, or nil if not found.
    static func encryptionKey(forUser email: String) -> Data? {
        readKeyData(account: encryptionKeyAccount(forUser: email))
    }

    /// Returns the existing encryption key for the user, or generates a new 32-byte AES-256 key.
    /// On first call after upgrade, migrates the legacy device-wide key to the user's account.
    static func getOrCreateEncryptionKey(forUser email: String) -> Data? {
        let account = encryptionKeyAccount(forUser: email)

        // 1. Check for existing per-user key
        if let existing = readKeyData(account: account) {
            return existing
        }

        // 2. Migrate legacy device-wide key if present
        if let legacy = readKeyData(account: legacyDeviceKeyAccount) {
            if storeKeyData(legacy, account: account) {
                deleteEncryptionKey(account: legacyDeviceKeyAccount)
                logger.info("Migrated legacy device key to per-user key")
            }
            return legacy
        }

        // 3. Generate a new cryptographically random 32-byte key
        var keyData = Data(count: 32)
        let result = keyData.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, 32, baseAddress)
        }
        guard result == errSecSuccess else {
            logger.error("Failed to generate random encryption key")
            return nil
        }

        guard storeKeyData(keyData, account: account) else { return nil }
        logger.info("Generated and stored new per-user encryption key")
        return keyData
    }

    // MARK: - Key Storage Helpers

    private static func readKeyData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return data
    }

    @discardableResult
    private static func storeKeyData(_ data: Data, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("Failed to store encryption key for \(account): \(status)")
            return false
        }
        return true
    }

    private static func deleteEncryptionKey(forUser email: String) {
        deleteEncryptionKey(account: encryptionKeyAccount(forUser: email))
    }

    private static func deleteEncryptionKey(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            logger.error("Keychain delete failed for \(account): \(status)")
        }
    }
}
