import Foundation

/// Somewhere to keep small secrets.
///
/// Declared here, in a Foundation-only target, so the things that need secrets
/// do not have to name `Security.framework` to get them. That matters twice
/// over: the harness builds this target on Linux where Security does not exist,
/// and a test needs to hand over a fake rather than negotiate with the real
/// Keychain.
///
/// Negotiating with the real Keychain is not a figure of speech. macOS ties an
/// item's ACL to the identity of the binary that created it, and the app's test
/// host is signed ad-hoc — `flags=0x20002(adhoc,linker-signed)`, no team
/// identifier — so its identity is its own cdhash and changes on every rebuild.
/// Each rebuild therefore looks like a different program asking for another
/// program's secret, and macOS raises a prompt that an unattended run will wait
/// on forever. That is what made the app-hosted suite sit for 300-500 seconds
/// with zero tests executed.
///
/// Keys are plain strings rather than an enum: this target has no business
/// knowing what the app chooses to store.
public protocol KeychainStoring: Sendable {
    func string(forKey key: String) -> String?
    func setString(_ value: String, forKey key: String)
    func data(forKey key: String) -> Data?
    func setData(_ value: Data, forKey key: String)
    func removeItem(forKey key: String)
}

/// A `KeychainStoring` that keeps everything in memory.
///
/// Ships in the module rather than a test target because both the app's tests
/// and the harness need it — the harness is an unsigned CLI with no Keychain
/// entitlements at all.
///
/// It behaves like a real store, which is the point: a test can round-trip a
/// value and assert on it, instead of asserting that nothing happened.
public final class InMemoryKeychain: KeychainStoring, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func string(forKey key: String) -> String? {
        // Failable rather than String(decoding:as:): a stored credential that is
        // not valid UTF-8 is corrupt, and should read as absent rather than as a
        // string full of replacement characters.
        data(forKey: key).flatMap { String(bytes: $0, encoding: .utf8) }
    }

    public func setString(_ value: String, forKey key: String) {
        setData(Data(value.utf8), forKey: key)
    }

    public func data(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    public func setData(_ value: Data, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = value
    }

    public func removeItem(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = nil
    }
}
