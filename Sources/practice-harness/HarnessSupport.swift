import CompanionSessionCore
import Foundation

/// Seals the harness's queue entries with no real cryptography.
///
/// The store encrypts entries at rest because on a therapist's machine they name
/// recording paths. The harness writes to a temp directory it deletes, and using
/// the real Keychain-backed encryptor here would make the run depend on Keychain
/// access an unsigned CLI does not have. The bytes under test are the audio and
/// the wire path, not the queue's at-rest format — that has its own unit tests.
struct PassthroughEncryptor: SessionDataEncrypting {
    func encrypt(_ data: Data) throws -> Data { data }
    func decrypt(_ data: Data) throws -> Data { data }
}

/// Mutable capture for the coordinator's `@Sendable` closures.
///
/// `UploadAttempt` is `@Sendable`, so the scenario cannot capture a local `var`
/// to record what came back. The harness is single-threaded here; this exists to
/// satisfy the compiler rather than to provide real concurrency safety.
final class Box<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
