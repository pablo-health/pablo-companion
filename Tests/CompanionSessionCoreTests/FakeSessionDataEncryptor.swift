@testable import CompanionSessionCore
import CryptoKit
import Foundation

/// A `SessionDataEncrypting` that seals with an in-memory key.
///
/// Stores under test previously constructed `RecordingEncryptor`, which reaches
/// the real login Keychain. Every run minted a key for a throwaway user, so it
/// prompted for access and left the key behind permanently — and an unanswered
/// prompt hangs the whole run.
///
/// The key is random per instance rather than a shared constant on purpose: the
/// stores keep every user's entries in one directory and `loadAll` decrypts
/// whatever it finds there, so a shared key would let one suite read another's
/// entries. Per-user Keychain keys had been supplying that isolation by
/// accident.
struct FakeSessionDataEncryptor: SessionDataEncrypting {
    private let key: SymmetricKey

    init(key: SymmetricKey = SymmetricKey(size: .bits256)) {
        self.key = key
    }

    func encrypt(_ data: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else {
            throw FakeEncryptorError.sealFailed
        }
        return combined
    }

    func decrypt(_ data: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
    }
}

enum FakeEncryptorError: Error {
    case sealFailed
}

/// Mutable capture for a `@Sendable` closure under test.
///
/// `SessionEncryptorFactory` is `@Sendable`, so a test cannot capture a local
/// `var` to record what it was called with. Tests are single-threaded here; this
/// exists to satisfy the compiler, not to provide real concurrency safety.
final class Box<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
