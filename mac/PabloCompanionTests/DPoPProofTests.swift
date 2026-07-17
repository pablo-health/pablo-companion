import CompanionAuthCore
import CryptoKit
import Foundation
@testable import Pablo
import Testing

/// Decodes the three segments of a compact JWS without verifying the signature,
/// for claim/header inspection in tests.
private enum CompactJWS {
    static func base64URLDecode(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while str.count % 4 != 0 {
            str += "="
        }
        return Data(base64Encoded: str)
    }

    static func segments(_ jws: String) -> (header: [String: Any], claims: [String: Any], signature: Data)? {
        let parts = jws.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let headerData = base64URLDecode(parts[0]),
              let claimsData = base64URLDecode(parts[1]),
              let sigData = base64URLDecode(parts[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try? JSONSerialization.jsonObject(with: claimsData) as? [String: Any]
        else {
            return nil
        }
        return (header, claims, sigData)
    }
}

/// .serialized because `init` resets and re-mints the device key, and Swift
/// Testing runs tests in parallel by default — so one test would delete the key
/// out from under another that was mid sign-then-verify, and the signature would
/// stop matching its own public key. Observed on CI as
/// signRoundTripsThroughRawForm and signatureVerifiesAgainstEnrolledDeviceKey
/// failing while everything passed locally.
@Suite("DPoP proof generation", .serialized)
struct DPoPProofTests {
    private let url = URL(string: "https://api.pablo.health/api/sessions?page=1&page_size=50#frag")!

    /// Provision a device key of this suite's own, before signing anything.
    ///
    /// Two things are going on.
    ///
    /// `DeviceKey.sign` only *loads* a key; `publicKey()` is what provisions one.
    /// Without that call `DPoPProof.make` returns nil on any machine that has
    /// never run the app, so every `#require` below throws — which is why these
    /// passed locally (a real run had left a key behind) and failed on every CI
    /// runner, invisibly, until the build started gating on its exit code.
    ///
    /// And the namespace matters. Sharing `health.pablo.companion` with the real
    /// app means reading a key some other build created — macOS grants a Keychain
    /// ACL to the exact binary that created an item, and an unsigned test host is
    /// a different binary after every rebuild, so it raises a system prompt and
    /// blocks in SecItemCopyMatching with nobody to click it. That is the hang
    /// that made `make test-mac` sit for 300-500 seconds with zero tests run.
    ///
    /// Owning a separate namespace lets the suite reset and mint its own key —
    /// creating never prompts — without touching the developer's real enrolment.
    init() {
        _ = DeviceKey.publicKey()
    }

    @Test func headerDeclaresDpopJwtAndES256() throws {
        let jws = try #require(DPoPProof.make(method: "GET", url: url))
        let parts = try #require(CompactJWS.segments(jws))
        #expect(parts.header["typ"] as? String == "dpop+jwt")
        #expect(parts.header["alg"] as? String == "ES256")
    }

    @Test func htmIsUppercasedMethod() throws {
        let jws = try #require(DPoPProof.make(method: "post", url: url))
        let parts = try #require(CompactJWS.segments(jws))
        #expect(parts.claims["htm"] as? String == "POST")
    }

    @Test func htuStripsQueryAndFragment() throws {
        // The backend compares htu against scheme+host+path with query/fragment
        // removed (_canonical_htu). Our claim must already be in that form.
        let jws = try #require(DPoPProof.make(method: "GET", url: url))
        let parts = try #require(CompactJWS.segments(jws))
        #expect(parts.claims["htu"] as? String == "https://api.pablo.health/api/sessions")
    }

    @Test func htuMatchesCanonicalHTUHelper() {
        // The helper is the single source of truth for the htu form.
        #expect(DPoPProof.canonicalHTU(url) == "https://api.pablo.health/api/sessions")
    }

    @Test func iatIsUnixSecondsNearNow() throws {
        let before = Int(Date().timeIntervalSince1970)
        let jws = try #require(DPoPProof.make(method: "GET", url: url))
        let after = Int(Date().timeIntervalSince1970)
        let parts = try #require(CompactJWS.segments(jws))
        let iat = try #require(parts.claims["iat"] as? Int)
        #expect(iat >= before && iat <= after)
    }

    @Test func jtiIsUniquePerProof() throws {
        let first = try #require(DPoPProof.make(method: "GET", url: url))
        let second = try #require(DPoPProof.make(method: "GET", url: url))
        let firstClaims = try #require(CompactJWS.segments(first)).claims
        let secondClaims = try #require(CompactJWS.segments(second)).claims
        let firstJti = try #require(firstClaims["jti"] as? String)
        let secondJti = try #require(secondClaims["jti"] as? String)
        #expect(!firstJti.isEmpty)
        #expect(firstJti != secondJti)
    }

    @Test func signatureIsRaw64ByteJOSEForm() throws {
        // ES256 (P-256) JOSE signatures are r||s = 32 + 32 = 64 bytes, NOT DER.
        // A DER signature would be ~70 bytes and start with 0x30 (SEQUENCE).
        let jws = try #require(DPoPProof.make(method: "GET", url: url))
        let parts = try #require(CompactJWS.segments(jws))
        #expect(parts.signature.count == 64)
        #expect(parts.signature.first != 0x30, "Signature must be raw r||s, not ASN.1 DER")
    }

    @Test func signatureVerifiesAgainstEnrolledDeviceKey() throws {
        // The signature over the signing input must verify against the same
        // public key the enrollment payload ships. This is the end-to-end DER->
        // raw correctness proof: DeviceKey.sign emits raw r||s, we reconstruct an
        // ECDSASignature from it and verify with the enrolled public JWK.
        let jws = try #require(DPoPProof.make(method: "GET", url: url))
        let parts = jws.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        let sigRaw = try #require(CompactJWS.base64URLDecode(parts[2]))

        // Rebuild the public key from the JWK the device would enroll.
        let publicKey = try Self.enrolledPublicKey(installID: "verify-install")

        let signature = try P256.Signing.ECDSASignature(rawRepresentation: sigRaw)
        #expect(publicKey.isValidSignature(signature, for: signingInput))
    }

    @Test func signRoundTripsThroughRawForm() throws {
        // Direct sign+verify round trip: DeviceKey.sign returns the JOSE raw
        // form; reconstructing the DER-equivalent ECDSASignature and verifying
        // proves the conversion is lossless and standards-correct.
        let message = Data("the quick brown fox".utf8)
        let raw = try #require(DeviceKey.sign(message))
        #expect(raw.count == 64)

        let publicKey = try Self.enrolledPublicKey(installID: "roundtrip")

        let signature = try P256.Signing.ECDSASignature(rawRepresentation: raw)
        #expect(publicKey.isValidSignature(signature, for: message))
    }

    // MARK: - Header attachment seam (enrollment state)

    @Test func attachesBothHeadersWhenEnrolled() {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        APIClient.attachDeviceBinding(
            to: &request,
            installID: "enrolled-install",
            makeProof: { _, _ in "proof.jws.sig" }
        )
        #expect(request.value(forHTTPHeaderField: "DPoP") == "proof.jws.sig")
        #expect(request.value(forHTTPHeaderField: "X-Install-ID") == "enrolled-install")
    }

    @Test func attachesNeitherHeaderWhenNotEnrolled() {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        APIClient.attachDeviceBinding(
            to: &request,
            installID: nil,
            makeProof: { _, _ in "proof.jws.sig" }
        )
        #expect(request.value(forHTTPHeaderField: "DPoP") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Install-ID") == nil)
    }

    @Test func neverSendsInstallIDWithoutProof() {
        // The load-bearing invariant: if signing fails, X-Install-ID must NOT be
        // sent alone — that combination is a guaranteed 401 once enforcement is
        // on. So an enrolled install whose proof factory returns nil gets neither.
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        APIClient.attachDeviceBinding(
            to: &request,
            installID: "enrolled-install",
            makeProof: { _, _ in nil }
        )
        #expect(request.value(forHTTPHeaderField: "X-Install-ID") == nil)
        #expect(request.value(forHTTPHeaderField: "DPoP") == nil)
    }

    @Test func emptyInstallIDIsTreatedAsNotEnrolled() {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        APIClient.attachDeviceBinding(
            to: &request,
            installID: "",
            makeProof: { _, _ in "proof.jws.sig" }
        )
        #expect(request.value(forHTTPHeaderField: "DPoP") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Install-ID") == nil)
    }

    @Test func proofFactoryReceivesRequestMethodAndURL() {
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        var seenMethod: String?
        var seenURL: URL?
        APIClient.attachDeviceBinding(
            to: &request,
            installID: "enrolled",
            makeProof: { method, requestURL in
                seenMethod = method
                seenURL = requestURL
                return "sig"
            }
        )
        #expect(seenMethod == "PATCH")
        #expect(seenURL == url)
    }

    /// The public key this install would enroll, rebuilt from the enrollment
    /// payload's JWK — i.e. exactly the key the backend would verify proofs
    /// against.
    private static func enrolledPublicKey(installID: String) throws -> P256.Signing.PublicKey {
        let payload = try #require(DeviceEnrollment.payload(installID: installID))
        let jwk = try #require(payload["device_public_key_jwk"] as? [String: String])
        return try publicKey(fromJWK: jwk)
    }

    /// Rebuilds a P-256 public key from an EC JWK ({kty,crv,x,y}) by
    /// reconstructing the uncompressed point 0x04 || X || Y.
    private static func publicKey(fromJWK jwk: [String: String]) throws -> P256.Signing.PublicKey {
        let x = try #require(jwk["x"].flatMap(CompactJWS.base64URLDecode))
        let y = try #require(jwk["y"].flatMap(CompactJWS.base64URLDecode))
        var point = Data([0x04])
        point.append(x)
        point.append(y)
        return try P256.Signing.PublicKey(x963Representation: point)
    }
}
