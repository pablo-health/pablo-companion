import Foundation
import Testing
@testable import Pablo

@Suite("JWTDecoder")
struct JWTDecoderTests {
    let decoder = JWTDecoder()

    /// Builds a minimal JWT with a given payload dictionary.
    func makeJWT(payload: [String: Any]) -> String {
        let header = #"{"alg":"RS256","typ":"JWT"}"#
        let payloadData = try! JSONSerialization.data(withJSONObject: payload)
        let headerB64 = Data(header.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let payloadB64 = payloadData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(headerB64).\(payloadB64).fakesig"
    }

    @Test func decodesValidJWT() {
        let jwt = makeJWT(payload: ["email": "user@example.com", "exp": 9_999_999_999.0])
        #expect(decoder.decodePayload(jwt) != nil)
    }

    @Test func extractsEmail() {
        let jwt = makeJWT(payload: ["email": "user@example.com"])
        #expect(decoder.extractEmail(from: jwt) == "user@example.com")
    }

    @Test func extractsExpiry() {
        let expiry: TimeInterval = 1_800_000_000
        let jwt = makeJWT(payload: ["exp": expiry])
        let date = decoder.extractExpiry(from: jwt)
        #expect(date == Date(timeIntervalSince1970: expiry))
    }

    @Test func returnsNilForMissingExpiry() {
        let jwt = makeJWT(payload: ["email": "user@example.com"])
        #expect(decoder.extractExpiry(from: jwt) == nil)
    }

    @Test func handlesURLSafeBase64Characters() {
        let jwt = makeJWT(payload: ["sub": "abc123", "exp": 9_999_999_999.0])
        #expect(decoder.decodePayload(jwt) != nil)
    }

    @Test func returnsNilForMalformedJWT() {
        #expect(decoder.decodePayload("onlyone") == nil)
        #expect(decoder.decodePayload("") == nil)
    }

    @Test func handlesPaddingVariants() {
        for size in [1, 2, 3, 4, 5, 6] {
            let payload: [String: Any] = ["k": String(repeating: "x", count: size)]
            let jwt = makeJWT(payload: payload)
            #expect(decoder.decodePayload(jwt) != nil, "Failed for size \(size)")
        }
    }
}
