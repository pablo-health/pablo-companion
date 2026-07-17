import Foundation
@testable import Pablo
import Testing

@Suite("URLValidator")
struct URLValidatorTests {
    @Test func httpsURLIsValid() {
        #expect(URLValidator.validateScheme("https://api.pablo.health") == nil)
    }

    @Test func httpsWithPathIsValid() {
        #expect(URLValidator.validateScheme("https://api.pablo.health/api/v1") == nil)
    }

    @Test func httpURLIsRejectedInRelease() {
        // In DEBUG builds, http://localhost is allowed; all other http is rejected.
        let result = URLValidator.validateScheme("http://evil.example.com")
        #expect(result != nil)
    }

    @Test func emptyURLIsRejected() throws {
        let result = URLValidator.validateScheme("")
        #expect(result != nil)
        #expect(try #require(result?.contains("empty")))
    }

    @Test func invalidURLFormatIsRejected() {
        let result = URLValidator.validateScheme("not a url at all :::")
        #expect(result != nil)
    }

    @Test func throwIfInvalidThrowsOnBadScheme() {
        #expect(throws: URLValidationError.self) {
            try URLValidator.throwIfInvalid("http://evil.example.com")
        }
    }

    @Test func throwIfInvalidPassesForHTTPS() throws {
        try URLValidator.throwIfInvalid("https://api.pablo.health")
    }
}
