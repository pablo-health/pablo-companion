import CryptoKit
import Foundation

// Standalone helpers lifted out of AuthViewModel: neither is auth state, both
// are pure functions, and AuthViewModel was past the file-length limit.

struct JWTDecoder {
    func decodePayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    func extractExpiry(from jwt: String) -> Date? {
        guard let payload = decodePayload(jwt),
              let exp = payload["exp"] as? TimeInterval
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    func extractEmail(from jwt: String) -> String? {
        decodePayload(jwt)?["email"] as? String
    }
}

// MARK: - PKCE (RFC 7636)

enum PKCEHelper {
    /// Generates a cryptographically random code verifier (43-128 URL-safe characters).
    static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Computes the S256 code challenge from a code verifier.
    static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Generates a cryptographically random OAuth 2.0 `state` value (RFC 6749 §10.12).
    /// Same entropy profile as the PKCE verifier.
    static func generateState() -> String {
        generateCodeVerifier()
    }

    /// Length-preserving, constant-time string comparison.
    /// Returns false if lengths differ (leaking only length, which is public).
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else { return false }
        var diff: UInt8 = 0
        for i in 0 ..< lhsBytes.count {
            diff |= lhsBytes[i] ^ rhsBytes[i]
        }
        return diff == 0
    }
}
