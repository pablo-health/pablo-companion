import CryptoKit
import Foundation
@testable import Pablo
import Testing

@Suite("Device enrollment payload")
struct DeviceEnrollmentTests {
    @Test func payloadContainsRequiredFields() throws {
        let payload = try #require(
            DeviceEnrollment.payload(installID: "11111111-2222-3333-4444-555555555555")
        )
        #expect(payload["install_id"] as? String == "11111111-2222-3333-4444-555555555555")
        #expect(payload["platform"] != nil)
        #expect(payload["os_version"] != nil)
        #expect(payload["hostname_hash"] != nil)
    }

    @Test func platformIsMacNotMacos() throws {
        // The shipped backend enum is mac|windows|linux — NOT "macos".
        #expect(DeviceEnrollment.platform == "mac")
        let payload = try #require(DeviceEnrollment.payload(installID: "x-install-id"))
        #expect(payload["platform"] as? String == "mac")
    }

    @Test func payloadCarriesDeviceKeyAndStorage() throws {
        // The backend `CompanionEnrollment` model requires both
        // `device_public_key_jwk` and `key_storage` (no defaults) — a partial
        // object 422s the entire OAuth exchange. Assert both are present and
        // well-formed so sign-in can't break against the shipped backend.
        let payload = try #require(DeviceEnrollment.payload(installID: "key-install-id"))

        let jwk = try #require(payload["device_public_key_jwk"] as? [String: String])
        #expect(jwk["kty"] == "EC")
        #expect(jwk["crv"] == "P-256")
        let x = try #require(jwk["x"])
        let y = try #require(jwk["y"])
        #expect(!x.isEmpty)
        #expect(!y.isEmpty)
        // base64url, no padding
        #expect(!x.contains("="))
        #expect(!x.contains("+"))
        #expect(!x.contains("/"))

        let storage = try #require(payload["key_storage"] as? String)
        #expect(storage == "hardware" || storage == "software")
    }

    @Test func jwkEncodesP256PublicKeyAsTwoCoordinates() throws {
        // A P-256 public key encodes as the two 32-byte X/Y coordinates,
        // base64url without padding. A 32-byte value is 43 base64url chars.
        let key = P256.Signing.PrivateKey()
        let jwk = try #require(DeviceKey.jwk(from: key.publicKey))
        #expect(jwk["kty"] == "EC")
        #expect(jwk["crv"] == "P-256")
        #expect(jwk["x"]?.count == 43)
        #expect(jwk["y"]?.count == 43)
    }

    @Test func hostnameHashIsLowercaseHexSHA256() {
        let hash = DeviceEnrollment.hostnameHash()
        #expect(hash.count == 64)
        let hexPattern = #"^[0-9a-f]{64}$"#
        #expect(hash.range(of: hexPattern, options: .regularExpression) != nil)
    }

    @Test func hostnameHashMatchesSHA256OfHostname() {
        // The emitted value is exactly SHA-256(hostname) in lowercase hex — proving
        // it's a privacy-preserving digest, never the raw hostname.
        let raw = Host.current().localizedName ?? ""
        let expected = SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        #expect(DeviceEnrollment.hostnameHash() == expected)
    }

    @Test func hostnameHashIsStable() {
        let first = DeviceEnrollment.hostnameHash()
        let second = DeviceEnrollment.hostnameHash()
        #expect(first == second)
    }
}
