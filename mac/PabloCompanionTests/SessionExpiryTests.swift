import Foundation
import Testing
@testable import Pablo

/// Covers the server-side session-expiry plumbing: the 401 → re-auth hook on
/// APIClient, the idle-timeout error-code detection, the SessionLiveness
/// response decoding, and the user-facing messaging.
@MainActor
@Suite("Server session expiry")
struct SessionExpiryTests {
    private func makeResponse(statusCode: Int) -> HTTPURLResponse? {
        HTTPURLResponse(
            url: URL(fileURLWithPath: "/api/test"),
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )
    }

    private func idleTimeoutBody() -> Data {
        Data(#"{"error": {"code": "IDLE_TIMEOUT", "message": "Session expired"}}"#.utf8)
    }

    // MARK: - 401 hook

    @Test func idleTimeout401FiresAuthRejectedWithIdleFlag() throws {
        let client = APIClient()
        var rejected: Bool?
        client.onAuthRejected = { rejected = $0 }

        let response = try #require(makeResponse(statusCode: 401))
        #expect(throws: PabloError.self) {
            try client.mapHTTPErrors(data: idleTimeoutBody(), response: response)
        }
        #expect(rejected == true)
    }

    @Test func generic401FiresAuthRejectedWithoutIdleFlag() throws {
        let client = APIClient()
        var rejected: Bool?
        client.onAuthRejected = { rejected = $0 }

        let response = try #require(makeResponse(statusCode: 401))
        let body = Data(#"{"error": {"code": "UNAUTHENTICATED", "message": "nope"}}"#.utf8)
        #expect(throws: PabloError.self) {
            try client.mapHTTPErrors(data: body, response: response)
        }
        #expect(rejected == false)
    }

    @Test func envelopeFree401StillFiresAuthRejected() throws {
        let client = APIClient()
        var rejected: Bool?
        client.onAuthRejected = { rejected = $0 }

        let response = try #require(makeResponse(statusCode: 401))
        #expect(throws: PabloError.self) {
            try client.mapHTTPErrors(data: Data("Unauthorized".utf8), response: response)
        }
        #expect(rejected == false)
    }

    @Test func non401DoesNotFireAuthRejected() throws {
        let client = APIClient()
        var fired = false
        client.onAuthRejected = { _ in fired = true }

        let response = try #require(makeResponse(statusCode: 403))
        #expect(throws: PabloError.self) {
            try client.mapHTTPErrors(data: Data(), response: response)
        }
        #expect(!fired)
    }

    @Test func successStatusDoesNotFireAuthRejected() throws {
        let client = APIClient()
        var fired = false
        client.onAuthRejected = { _ in fired = true }

        let response = try #require(makeResponse(statusCode: 200))
        try client.mapHTTPErrors(data: Data(), response: response)
        #expect(!fired)
    }

    // MARK: - SessionLiveness decoding

    @Test func sessionLivenessDecodesSnakeCase() throws {
        let json = Data(#"{"enforced": true, "active": true, "seconds_remaining": 542}"#.utf8)
        let status = try JSONDecoder().decode(SessionLiveness.self, from: json)
        #expect(status.enforced)
        #expect(status.active)
        #expect(status.secondsRemaining == 542)
    }

    @Test func sessionLivenessDecodesDeadSessionWithoutRemaining() throws {
        let json = Data(#"{"enforced": true, "active": false, "seconds_remaining": null}"#.utf8)
        let status = try JSONDecoder().decode(SessionLiveness.self, from: json)
        #expect(status.enforced)
        #expect(!status.active)
        #expect(status.secondsRemaining == nil)
    }

    // MARK: - Messaging

    @Test func idleTimeoutMessageIsDistinctFromGenericMessage() {
        let idle = AuthViewModel.sessionRejectedMessage(idleTimeout: true)
        let generic = AuthViewModel.sessionRejectedMessage(idleTimeout: false)
        #expect(idle != generic)
        #expect(idle.localizedCaseInsensitiveContains("inactivity"))
        #expect(idle.localizedCaseInsensitiveContains("sign in"))
        #expect(generic.localizedCaseInsensitiveContains("sign in"))
    }
}
