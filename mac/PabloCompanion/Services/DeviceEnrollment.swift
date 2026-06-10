import CryptoKit
import Foundation

/// Builds the device-enrollment payload that rides along with the OAuth code
/// exchange (`POST /api/auth/native/exchange`). The backend stores this as a
/// `companion_devices` row keyed by `(user_id, install_id)` so the web dashboard
/// can recognise an enrolled install and route handoffs to it.
///
/// The payload is privacy-preserving: only an opaque install identifier, the OS
/// version string, a SHA-256 hash of the machine hostname, and the **public**
/// half of the device keypair leave the device — never the raw hostname, the
/// private key, or any PHI.
enum DeviceEnrollment {
    /// Platform tag for this build. The backend's stored enum is
    /// `mac | windows | linux` — NOT `macos`.
    static let platform = "mac"

    /// Assembles the full enrollment object for the OAuth code exchange.
    ///
    /// Field names and types match the backend `CompanionEnrollment` model
    /// exactly. `device_public_key_jwk` and `key_storage` are **required** by the
    /// shipped model (no defaults) — a partial object would 422 the entire
    /// exchange before the handler runs. Returns `nil` only if no device key can
    /// be provisioned, in which case the caller omits the enrollment object
    /// entirely (the backend treats `enrollment` as optional) rather than sending
    /// a schema-invalid partial.
    static func payload(installID: String) -> [String: Any]? {
        guard let key = DeviceKey.publicKey() else { return nil }
        return [
            "install_id": installID,
            "platform": platform,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "hostname_hash": hostnameHash(),
            "device_public_key_jwk": key.jwk,
            "key_storage": key.storage.rawValue,
        ]
    }

    /// SHA-256 hex (lowercase) of the local hostname. Returns the hash of an empty
    /// string when no hostname is available — never the raw hostname.
    static func hostnameHash() -> String {
        let hostname = Host.current().localizedName ?? ""
        let digest = SHA256.hash(data: Data(hostname.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
