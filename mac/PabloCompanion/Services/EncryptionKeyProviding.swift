import Foundation

/// Supplies the per-user AES key that `RecordingEncryptor` seals with.
///
/// This exists so the encryptor — and every store built on it — can be
/// exercised without the real Keychain. `KeychainManager` is a static facade
/// over Security.framework, which leaves callers no seam and has two costs:
///
/// - Tests hit the developer's real login Keychain. `PendingAudioUploadStore`
///   tests mint a fresh per-run user key, so every run prompts for access and
///   leaves items behind permanently.
/// - The key-unavailable path is untestable. That is the exact failure class
///   behind the Windows pending-store cache poisoning, where a null key at the
///   wrong moment silently emptied the queue.
///
/// It is also a prerequisite for moving the stores into `CompanionSessionCore`:
/// that target is deliberately Foundation-only so the harness can build on
/// Linux, and Security.framework does not exist there.
protocol EncryptionKeyProviding: Sendable {
    /// The key for `userEmail`, generating one on first use.
    ///
    /// A nil `userEmail` means the legacy device-wide key, used by standalone
    /// recordings made before sign-in. Returns nil when no key can be provided,
    /// which callers must treat as "do not write" rather than "write plaintext".
    func key(forUser userEmail: String?) -> Data?
}

/// The production provider, backed by the login Keychain.
struct KeychainEncryptionKeyProvider: EncryptionKeyProviding {
    func key(forUser userEmail: String?) -> Data? {
        guard let userEmail else {
            // Legacy fallback for standalone recordings with no signed-in user.
            return KeychainManager.encryptionKey(forUser: "")
                ?? KeychainManager.getOrCreateEncryptionKey(forUser: "")
        }
        return KeychainManager.getOrCreateEncryptionKey(forUser: userEmail)
    }
}
