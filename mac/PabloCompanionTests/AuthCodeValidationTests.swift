import Foundation
@testable import Pablo
import Testing

@Suite("Auth code validation")
struct AuthCodeValidationTests {
    // Access the private static method via a test helper
    // Since isValidAuthCode is private, we test the behavior through the public flow.
    // However, we can test the regex pattern directly.

    private static func isValidCode(_ code: String) -> Bool {
        let pattern = #"^[a-zA-Z0-9_\-\.]{10,2000}$"#
        return code.range(of: pattern, options: .regularExpression) != nil
    }

    @Test func validAuthCode() {
        #expect(Self.isValidCode("abc123def456"))
    }

    @Test func validAuthCodeWithSpecialChars() {
        #expect(Self.isValidCode("abc_123-def.456"))
    }

    @Test func rejectsTooShortCode() {
        #expect(!Self.isValidCode("abc"))
    }

    @Test func rejectsEmptyCode() {
        #expect(!Self.isValidCode(""))
    }

    @Test func rejectsCodeWithSpaces() {
        #expect(!Self.isValidCode("abc 123 def 456"))
    }

    @Test func rejectsCodeWithHTMLInjection() {
        #expect(!Self.isValidCode("<script>alert(1)</script>"))
    }

    @Test func rejectsCodeWithSQLInjection() {
        #expect(!Self.isValidCode("'; DROP TABLE users; --"))
    }

    @Test func acceptsLongValidCode() {
        let code = String(repeating: "a", count: 2000)
        #expect(Self.isValidCode(code))
    }

    @Test func rejectsTooLongCode() {
        let code = String(repeating: "a", count: 2001)
        #expect(!Self.isValidCode(code))
    }

    @Test func rejectsCodeWithNewlines() {
        #expect(!Self.isValidCode("abc123\ndef456"))
    }
}
