import Crypto
import Foundation

/// RFC 6238 TOTP, matching the e2e suite's `otplib` authenticator defaults
/// (HMAC-SHA1, 6 digits, 30-second step). Used only by the harness to sign the
/// pinned test user in; it is not part of the shipping client.
enum TOTP {
    static func code(base32Secret: String, date: Date = Date()) -> String {
        let key = base32Decode(base32Secret)
        let counter = UInt64(date.timeIntervalSince1970 / 30)
        var bigEndian = counter.bigEndian
        let counterData = withUnsafeBytes(of: &bigEndian) { Data($0) }

        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: counterData, using: SymmetricKey(data: key)
        )
        let hash = Data(mac)

        let offset = Int(hash[hash.count - 1] & 0x0F)
        let binary = (UInt32(hash[offset] & 0x7F) << 24)
            | (UInt32(hash[offset + 1]) << 16)
            | (UInt32(hash[offset + 2]) << 8)
            | UInt32(hash[offset + 3])
        return String(format: "%06u", binary % 1_000_000)
    }

    /// Wait for the start of a fresh 30s window before generating a code, so it
    /// isn't milliseconds from expiry when the server checks it. Mirrors
    /// `freshTotp` in the e2e suite (wait into the last 3s, then 3s past the
    /// boundary).
    static func freshCode(base32Secret: String) async throws -> String {
        while 30 - Int(Date().timeIntervalSince1970) % 30 >= 3 {
            try await Task.sleep(for: .milliseconds(500))
        }
        try await Task.sleep(for: .seconds(3))
        return code(base32Secret: base32Secret)
    }

    /// RFC 4648 base32 decode (upper-case alphabet, padding/space tolerant).
    static func base32Decode(_ s: String) -> Data {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var lookup = [Character: Int]()
        for (i, c) in alphabet.enumerated() { lookup[c] = i }

        var bits = 0
        var value = 0
        var out = Data()
        for c in s.uppercased() where c != " " && c != "=" {
            guard let v = lookup[c] else { continue }
            value = (value << 5) | v
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((value >> bits) & 0xFF))
            }
        }
        return out
    }
}
