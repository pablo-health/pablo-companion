import Foundation
@testable import Pablo

/// An `EncryptionKeyProviding` that keeps keys in memory.
///
/// Stores under test previously reached the real login Keychain through
/// `KeychainManager`'s static facade, which prompted the developer for access
/// on every run and left a key behind permanently for each test's throwaway
/// user. This substitutes for it: no prompts, no residue, no shared state
/// between suites.
///
/// It also makes the key-unavailable branch reachable — set `key` to nil and a
/// store must refuse to write rather than write something wrong. That branch had
/// no test at all, and it is the same failure class as the Windows pending-store
/// cache poisoning, where a null key at the wrong moment silently emptied the
/// queue.
final class InMemoryEncryptionKeyProvider: EncryptionKeyProviding, @unchecked Sendable {
    /// The key handed to every caller. Set to nil to simulate an unavailable key.
    var key: Data?

    /// Emails this provider was asked for, in order — lets a test assert that a
    /// store scoped its key to the signed-in user rather than the device-wide one.
    private(set) var requestedUsers: [String?] = []

    /// - Parameter key: defaults to a fresh random 32-byte AES-256 key.
    ///
    /// The default is random per instance, not a shared constant, because the
    /// stores keep every user's entries in one directory and `loadAll` decrypts
    /// whatever it finds there. A constant key would let one suite decrypt
    /// another's entries and see them in its own results — isolation these tests
    /// used to get for free from per-user Keychain keys.
    init(key: Data? = Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) })) {
        self.key = key
    }

    func key(forUser userEmail: String?) -> Data? {
        requestedUsers.append(userEmail)
        return key
    }
}
