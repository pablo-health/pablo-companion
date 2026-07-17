import Foundation
@testable import Pablo
import Testing

@Suite("OAuth state (RFC 6749 §10.12) helpers")
struct OAuthStateTests {
    @Test func generatesURLSafeState() {
        let state = PKCEHelper.generateState()
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        for ch in state {
            #expect(allowed.contains(ch), "state contained non-URL-safe char: \(ch)")
        }
    }

    @Test func stateHasSufficientEntropy() {
        // 256 bits of randomness → 32 bytes → at least 43 base64url chars (no padding).
        let state = PKCEHelper.generateState()
        #expect(state.count >= 43)
    }

    @Test func generatesUniqueStates() {
        // 100 draws of a 256-bit random value: collision probability is negligible.
        var seen = Set<String>()
        for _ in 0 ..< 100 {
            seen.insert(PKCEHelper.generateState())
        }
        #expect(seen.count == 100)
    }

    @Test func constantTimeEqualsAcceptsEqualStrings() {
        #expect(PKCEHelper.constantTimeEquals("abc123", "abc123"))
    }

    @Test func constantTimeEqualsRejectsDifferentStrings() {
        #expect(!PKCEHelper.constantTimeEquals("abc123", "abc124"))
    }

    @Test func constantTimeEqualsRejectsDifferentLengths() {
        #expect(!PKCEHelper.constantTimeEquals("abc", "abcd"))
    }

    @Test func constantTimeEqualsRejectsEmptyVsNonEmpty() {
        #expect(!PKCEHelper.constantTimeEquals("", "abc"))
    }

    @Test func constantTimeEqualsHandlesEmptyStrings() {
        #expect(PKCEHelper.constantTimeEquals("", ""))
    }
}
