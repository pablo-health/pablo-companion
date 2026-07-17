import Foundation

/// Encrypts and decrypts session data held at rest — pending upload queues and
/// the session/recording map.
///
/// This lives here, rather than in the app, so those stores can eventually move
/// into this target. They must not name `RecordingEncryptor`: it conforms to
/// AudioCaptureKit's `CaptureEncryptor`, and AudioCaptureKit is `.macOS(.v14)`
/// only, whereas this target is deliberately Foundation-only so the harness can
/// build on Linux. A store that names the concrete type drags a macOS-only
/// package across that line — and, once moved, would import the app module,
/// which is circular.
///
/// The app conforms `RecordingEncryptor` to this and injects it. Tests inject a
/// fake, which is what keeps them off the real Keychain.
public protocol SessionDataEncrypting: Sendable {
    func encrypt(_ data: Data) throws -> Data
    func decrypt(_ data: Data) throws -> Data
}

/// Builds an encryptor for a given user, or nil when no key is available.
///
/// A factory rather than a single instance because the stores are long-lived and
/// the signed-in user changes underneath them; they resolve an encryptor per
/// call, scoped to whoever is signed in at that moment.
///
/// Returning nil must mean "do not write" — never "write it unencrypted".
public typealias SessionEncryptorFactory = @Sendable (_ userEmail: String?) -> SessionDataEncrypting?
