import Foundation
import os

/// Builds DPoP-style proof JWTs for device-bound requests.
///
/// The companion signs a fresh proof per request with its Secure-Enclave /
/// software device key (see `DeviceKey`). The backend middleware
/// (`backend/app/middleware/dpop.py`) verifies the proof against the public JWK
/// the device enrolled, bound to the `install_id` rather than the access token's
/// `cnf.jkt` — the deviation is documented in
/// `docs/design/companion-dpop-binding.md`.
///
/// Wire format (compact JWS, RFC 7515):
/// - header  `{"typ":"dpop+jwt","alg":"ES256"}`
/// - payload `{"htm": <METHOD>, "htu": <url w/o query+fragment>, "iat": <unix s>, "jti": <random>}`
/// - signature ES256 over `base64url(header) + "." + base64url(payload)`, JOSE
///   raw `r || s` (64 bytes) — NOT ASN.1/DER.
enum DPoPProof {
    private static let logger = Logger(subsystem: AppConstants.appBundleID, category: "DPoPProof")

    /// Builds a signed compact-JWS proof for `method` + `url`, or `nil` if the
    /// device key is unavailable (caller then attaches neither DPoP nor
    /// X-Install-ID — never one without the other).
    ///
    /// `now`/`jti` are injectable for tests; production callers omit them.
    static func make(
        method: String,
        url: URL,
        now: Date = Date(),
        jti: String = UUID().uuidString
    ) -> String? {
        let header = #"{"typ":"dpop+jwt","alg":"ES256"}"#

        let claims: [String: Any] = [
            "htm": method.uppercased(),
            "htu": canonicalHTU(url),
            "iat": Int(now.timeIntervalSince1970),
            "jti": jti,
        ]
        guard let payloadData = try? JSONSerialization.data(
            withJSONObject: claims,
            options: [.sortedKeys]
        ) else {
            logger.error("Failed to encode DPoP claims")
            return nil
        }

        let signingInput = DeviceKey.base64URLNoPadding(Data(header.utf8))
            + "."
            + DeviceKey.base64URLNoPadding(payloadData)

        guard let signature = DeviceKey.sign(Data(signingInput.utf8)) else {
            // DeviceKey already logged the (non-sensitive) reason.
            return nil
        }

        return signingInput + "." + DeviceKey.base64URLNoPadding(signature)
    }

    /// The `htu` claim value: scheme + host (+ port) + path, with the query
    /// string and fragment stripped, matching the backend's `_canonical_htu`
    /// comparison (RFC 9449 §4.3). The middleware also strips query/fragment from
    /// the claimed `htu` before comparing, so any residual difference is in the
    /// path only — which we preserve verbatim.
    static func canonicalHTU(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            // No safe normalization possible — fall back to the raw absolute
            // string so signing still produces a deterministic value.
            return url.absoluteString
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? url.absoluteString
    }
}
