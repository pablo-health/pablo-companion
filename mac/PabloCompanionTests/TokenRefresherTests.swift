import Foundation
import Testing
@testable import PabloCompanion

@Suite("TokenRefresher error classification")
struct TokenRefresherTests {
    let refresher = TokenRefresher(apiKey: "test-key")

    func makeErrorBody(_ message: String) -> Data {
        let json: [String: Any] = ["error": ["message": message]]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test func tokenExpiredMapsToRevoked() {
        let error = refresher.classifyRefreshError(from: makeErrorBody("TOKEN_EXPIRED"))
        if case .tokenRevoked = error { } else { Issue.record("Expected .tokenRevoked, got \(error)") }
    }

    @Test func invalidRefreshTokenMapsToRevoked() {
        let error = refresher.classifyRefreshError(from: makeErrorBody("INVALID_REFRESH_TOKEN"))
        if case .tokenRevoked = error { } else { Issue.record("Expected .tokenRevoked, got \(error)") }
    }

    @Test func userDisabledMapsToUserDisabled() {
        let error = refresher.classifyRefreshError(from: makeErrorBody("USER_DISABLED"))
        if case .userDisabled = error { } else { Issue.record("Expected .userDisabled, got \(error)") }
    }

    @Test func unknownErrorMapsToServerError() {
        let error = refresher.classifyRefreshError(from: makeErrorBody("SOME_UNKNOWN_CODE"))
        if case let .serverError(message) = error {
            #expect(message == "SOME_UNKNOWN_CODE")
        } else {
            Issue.record("Expected .serverError, got \(error)")
        }
    }

    @Test func malformedBodyMapsToServerError() {
        let error = refresher.classifyRefreshError(from: Data("not json".utf8))
        if case .serverError = error { } else { Issue.record("Expected .serverError for malformed body") }
    }
}
