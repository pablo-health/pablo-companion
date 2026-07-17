import CompanionSessionCore
import Foundation
import os

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

    private static let logger = Logger(subsystem: AppConstants.appBundleID, category: "KeychainManager")

    /// Where secrets actually live.
    ///
    /// Injectable so a test can hand over an in-memory store instead of talking
    /// to the real Keychain. That is not a convenience: macOS ties an item's ACL
    /// to the identity of the binary that created it, and the app's test host is
    /// signed ad-hoc — its identity is its own cdhash and changes on every
    /// rebuild — so each rebuild looks like a different program asking for
    /// another program's secret and macOS raises a prompt nobody is there to
    /// click. The app-hosted suite sat for 300-500 seconds with zero tests
    /// executed.
    ///
    /// The default is chosen once, here, rather than branching on "am I under
    /// test" inside every method: production code should not know tests exist.
    /// Signing the host with a stable identity would remove even this, but the
    /// app needs a provisioning profile for its Associated Domains and Keychain
    /// access group, which is why signing is disabled in the first place.
    nonisolated(unsafe) static var backend: KeychainStoring =
        PabloCompanionApp.isRunningTests ? InMemoryKeychain() : SecurityKeychain()

    static func saveToken(_ value: String, forKey key: TokenKey) {
        backend.setString(value, forKey: key.rawValue)
    }

    static func getToken(forKey key: TokenKey) -> String? {
        backend.string(forKey: key.rawValue)
    }

    static func deleteToken(forKey key: TokenKey) {
        backend.removeItem(forKey: key.rawValue)
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

    // MARK: - Install Identity

    /// Returns the stable per-install identifier, generating and persisting a new
    /// UUIDv4 on first call. Persisted across sign-outs (excluded from
    /// `deleteAuthTokens()`) so a single companion install keeps one identity for
    /// its lifetime — same survive-sign-out treatment as the encryption key.
    static func getOrCreateInstallID() -> String {
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
        backend.data(forKey: account)
    }

    @discardableResult
    private static func storeKeyData(_ data: Data, account: String) -> Bool {
        backend.setData(data, forKey: account)
        return true
    }

    private static func deleteEncryptionKey(forUser email: String) {
        deleteEncryptionKey(account: encryptionKeyAccount(forUser: email))
    }

    private static func deleteEncryptionKey(account: String) {
        backend.removeItem(forKey: account)
    }
}
