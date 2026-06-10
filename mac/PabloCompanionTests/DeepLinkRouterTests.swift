import Foundation
@testable import Pablo
import Testing

@Suite("DeepLinkAction parsing")
struct DeepLinkRouterTests {
    private func action(_ string: String) -> DeepLinkAction {
        guard let url = URL(string: string) else {
            return .unsupported(reason: "unparseable")
        }
        return DeepLinkAction(url: url)
    }

    // MARK: - Universal Links (https://<host>/launch/<intent_id>)

    @Test func universalLinkProdHostRedeemsIntent() {
        let intent = "abcDEF123456_-xyz"
        #expect(
            action("https://app.pablo.health/launch/\(intent)")
                == .redeemLaunchIntent(intentId: intent)
        )
    }

    @Test func universalLinkDevHostRedeemsIntent() {
        let intent = "devIntent0123456789"
        #expect(
            action("https://dev.pablo.health/launch/\(intent)")
                == .redeemLaunchIntent(intentId: intent)
        )
    }

    @Test func universalLinkUntrustedHostIsRejected() {
        if case .redeemLaunchIntent = action("https://evil.example.com/launch/abcDEF123456_-xyz") {
            Issue.record("Untrusted host must not redeem an intent")
        }
    }

    @Test func universalLinkWrongPathIsUnsupported() {
        if case .redeemLaunchIntent = action("https://app.pablo.health/dashboard/abcDEF123456789") {
            Issue.record("Non-/launch path must not redeem an intent")
        }
    }

    @Test func universalLinkExtraPathSegmentIsUnsupported() {
        // Only exactly /launch/<id> is honoured — guards against /launch/<id>/extra.
        if case .redeemLaunchIntent = action("https://app.pablo.health/launch/abcDEF123456789/extra") {
            Issue.record("Deeper path must not redeem an intent")
        }
    }

    @Test func universalLinkRejectsMalformedIntentId() {
        if case .redeemLaunchIntent = action("https://app.pablo.health/launch/<script>") {
            Issue.record("Malformed intent id must be rejected")
        }
    }

    @Test func universalLinkHostIsCaseInsensitive() {
        let intent = "MixedCaseHost123456"
        #expect(
            action("https://APP.Pablo.Health/launch/\(intent)")
                == .redeemLaunchIntent(intentId: intent)
        )
    }

    // MARK: - Legacy scheme: intent grammar (pablohealth://session/start?intent=)

    @Test func legacySchemeIntentParamRedeems() {
        let intent = "legacyIntent01234567"
        #expect(
            action("pablohealth://session/start?intent=\(intent)")
                == .redeemLaunchIntent(intentId: intent)
        )
    }

    @Test func legacySchemeIntentTakesPriorityOverAppointment() {
        // Per the contract: when an intent is present, the appointment param is ignored.
        let intent = "priorityIntent012345"
        #expect(
            action("pablohealth://session/start?appointment=appt-999&intent=\(intent)")
                == .redeemLaunchIntent(intentId: intent)
        )
    }

    @Test func legacyLaunchHostRedeemsIntent() {
        let intent = "schemeLaunch01234567"
        #expect(
            action("pablohealth://launch/\(intent)")
                == .redeemLaunchIntent(intentId: intent)
        )
    }

    // MARK: - Legacy scheme: appointment fallback (no intent present)

    @Test func legacySchemeAppointmentFallback() {
        #expect(
            action("pablohealth://session/start?appointment=appt-123")
                == .startSessionFromAppointment(appointmentId: "appt-123")
        )
    }

    @Test func legacySchemeNoParamsIsUnsupported() {
        if case .startSessionFromAppointment = action("pablohealth://session/start") {
            Issue.record("session/start with no params must not start a session")
        }
        if case .redeemLaunchIntent = action("pablohealth://session/start") {
            Issue.record("session/start with no params must not redeem")
        }
    }

    @Test func legacySchemeEmptyAppointmentIsUnsupported() {
        if case .startSessionFromAppointment = action("pablohealth://session/start?appointment=") {
            Issue.record("Empty appointment must not start a session")
        }
    }

    // MARK: - Scheme rejection

    @Test func nonPabloSchemeIsUnsupported() {
        if case .unsupported = action("ftp://app.pablo.health/launch/abcDEF123456789") {
            // expected
        } else {
            Issue.record("Unknown scheme must be unsupported")
        }
    }

    @Test func httpSchemeIsNotTreatedAsUniversalLink() {
        // Universal Links are https only; plain http must not redeem.
        if case .redeemLaunchIntent = action("http://app.pablo.health/launch/abcDEF123456789") {
            Issue.record("http (non-TLS) must not redeem an intent")
        }
    }

    // MARK: - Intent id validation

    @Test func intentIdAcceptsBase64URL22Chars() {
        // secrets.token_urlsafe(16) → 22 chars, base64url alphabet.
        #expect(DeepLinkAction.isValidIntentId("AbCdEfGhIjKlMnOpQrStUv"))
    }

    @Test func intentIdRejectsTooShort() {
        #expect(!DeepLinkAction.isValidIntentId("short"))
    }

    @Test func intentIdRejectsInjection() {
        #expect(!DeepLinkAction.isValidIntentId("'; DROP TABLE intents; --"))
        #expect(!DeepLinkAction.isValidIntentId("<script>alert(1)</script>"))
    }

    @Test func intentIdRejectsSlash() {
        // A slash would let an attacker smuggle extra path structure.
        #expect(!DeepLinkAction.isValidIntentId("abc/def/ghi/jkl/mno"))
    }
}
