import CryptoKit
import Foundation
@testable import Pablo
import Testing

@Suite("Device enrollment payload")
struct DeviceEnrollmentTests {
    @Test func payloadContainsRequiredFields() {
        let payload = DeviceEnrollment.payload(installID: "11111111-2222-3333-4444-555555555555")
        #expect(payload["install_id"] == "11111111-2222-3333-4444-555555555555")
        #expect(payload["platform"] != nil)
        #expect(payload["os_version"] != nil)
        #expect(payload["hostname_hash"] != nil)
    }

    @Test func platformIsMacNotMacos() {
        // The shipped backend enum is mac|windows|linux — NOT "macos".
        #expect(DeviceEnrollment.platform == "mac")
        #expect(DeviceEnrollment.payload(installID: "x")["platform"] == "mac")
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
