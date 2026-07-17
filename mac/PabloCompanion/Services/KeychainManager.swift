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
        case installID = "install_id"
    }

    private static let serviceName = AppConstants.appBundleID
    private static let accessGroup = AppConstants.keychainAccessGroup
    private static let logger = Logger(subsystem: AppConstants.appBundleID, category: "KeychainManager")

    /// Under test, every read misses and every write is dropped.
    ///
    /// The unit tests are app-hosted, so xcodebuild launches this app for real
    /// and it reads the Keychain on the way up. macOS ties an item's ACL to the
    /// identity of the binary that created it, and the test host is signed
    /// ad-hoc — `flags=0x20002(adhoc,linker-signed)`, `TeamIdentifier=not set` —
    /// so its identity IS its cdhash and changes on every rebuild. Each rebuild
    /// therefore looks like a different program asking for another program's
    /// secret, and macOS puts up a prompt nobody is there to click: the run
    /// blocks in SecItemCopyMatching. `make test-mac` sat for 300-500 seconds
    /// with ZERO tests executed.
    ///
    /// Signing with a stable identity would fix it properly, but the app needs a
    /// provisioning profile for its Associated Domains and Keychain access group,
    /// which is why signing is disabled here in the first place. Until that is
    /// set up, the honest position is that a unit test has no business reading a
    /// developer's real credentials — so it doesn't.
    ///
    /// A test that needs Keychain behaviour should inject a fake. The stores in
    /// CompanionSessionCore already do exactly that, which is why `swift test`
    /// runs in 0.035s and prompts for nothing.
    private static var isUnderTest: Bool {
        PabloCompanionApp.isRunningTests
    }

    static func saveToken(_ value: String, forKey key: TokenKey) {
        guard !isUnderTest else { return }
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
        guard !isUnderTest else { return nil }
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
        guard !isUnderTest else { return }
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
        guard !isUnderTest else { return }
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
        guard !isUnderTest else { return }
        deleteAuthTokens()
        deleteEncryptionKey(forUser: email)
        // Also remove any legacy device-wide key
        deleteEncryptionKey(account: legacyDeviceKeyAccount)
    }

    // MARK: - Install Identity

    /// Returns the stable per-install identifier, generating and persisting a new
    /// UUIDv4 on first call. Persisted across sign-outs (excluded from
    /// `deleteAuthTokens()`) so a single companion install keeps one identity for
    /// its lifetime — same survive-sign-out treatment as the encryption key.
    static func getOrCreateInstallID() -> String {
        guard !isUnderTest else { return "test-install-id" }
        if let existing = getToken(forKey: .installID), !existing.isEmpty {
            return existing
        }
        let installID = UUID().uuidString
        saveToken(installID, forKey: .installID)
        return installID
    }

    /// Returns the persisted install identifier *without* creating one. Used by
    /// the per-request DPoP seam to decide "is this install enrolled?" — a
    /// request must never mint a fresh install_id as a side effect (the id is
    /// established at enrollment, alongside the device key). Returns `nil` before
    /// the first enrollment.
    static func installID() -> String? {
        guard !isUnderTest else { return nil }
        guard let existing = getToken(forKey: .installID), !existing.isEmpty else {
            return nil
        }
        return existing
    }

    // MARK: - Per-User Encryption Key

    private static let legacyDeviceKeyAccount = "device_encryption_key"

    private static func encryptionKeyAccount(forUser email: String) -> String {
        "device_encryption_key_\(email)"
    }

    /// Returns the encryption key for the given user, or nil if not found.
    static func encryptionKey(forUser email: String) -> Data? {
        guard !isUnderTest else { return nil }
        return readKeyData(account: encryptionKeyAccount(forUser: email))
    }

    /// Returns the existing encryption key for the user, or generates a new 32-byte AES-256 key.
    /// On first call after upgrade, migrates the legacy device-wide key to the user's account.
    static func getOrCreateEncryptionKey(forUser email: String) -> Data? {
        guard !isUnderTest else { return nil }
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
