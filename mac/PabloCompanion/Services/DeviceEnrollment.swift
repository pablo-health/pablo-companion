import CryptoKit
import Foundation

/// Builds the device-enrollment payload that rides along with the OAuth code
/// exchange (`POST /api/auth/native/exchange`). The backend stores this as a
/// `companion_devices` row keyed by `(user_id, install_id)` so the web dashboard
/// can recognise an enrolled install and route handoffs to it.
///
/// The payload is privacy-preserving: only an opaque install identifier, the OS
/// version string, and a SHA-256 hash of the machine hostname leave the device —
/// never the raw hostname or any PHI.
enum DeviceEnrollment {
    /// Platform tag for this build. The backend's stored enum is
    /// `mac | windows | linux` — NOT `macos`.
    static let platform = "mac"

    /// Assembles the enrollment dictionary for the given install identifier.
    /// Field names match the backend `CompanionEnrollment` model exactly.
    static func payload(installID: String) -> [String: String] {
        [
            "install_id": installID,
            "platform": platform,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "hostname_hash": hostnameHash(),
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
