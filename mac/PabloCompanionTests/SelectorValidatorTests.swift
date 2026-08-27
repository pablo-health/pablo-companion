import Foundation
@testable import Pablo
import Testing

@Suite("SelectorValidator")
struct SelectorValidatorTests {
    @Test func validCSSSelector() throws {
        try SelectorValidator.validate("div.form-group > input[name='note']")
    }

    @Test func validIdSelector() throws {
        try SelectorValidator.validate("#soap-note-textarea")
    }

    @Test func rejectsJavascriptProtocol() {
        #expect(throws: (any Error).self) {
            try SelectorValidator.validate("javascript:alert(1)")
        }
    }

    @Test func rejectsDocumentCookie() {
        #expect(throws: (any Error).self) {
            try SelectorValidator.validate("div[data-x='document.cookie']")
        }
    }

    @Test func rejectsEval() {
        #expect(throws: (any Error).self) {
            try SelectorValidator.validate("eval(something)")
        }
    }

    @Test func rejectsFetch() {
        #expect(throws: (any Error).self) {
            try SelectorValidator.validate("fetch(url)")
        }
    }

    @Test func rejectsScriptTag() {
        #expect(throws: (any Error).self) {
            try SelectorValidator.validate("<script>alert(1)</script>")
        }
    }

    @Test func rejectsEventHandlers() {
        #expect(throws: (any Error).self) {
            try SelectorValidator.validate("img onerror=alert(1)")
        }
    }

    @Test func rejectsOverlyLongSelector() {
        let longSelector = String(repeating: "a", count: 501)
        #expect(throws: (any Error).self) {
            try SelectorValidator.validate(longSelector)
        }
    }

    @Test func acceptsMaxLengthSelector() throws {
        let selector = String(repeating: "a", count: 500)
        try SelectorValidator.validate(selector)
    }

    @Test func caseInsensitiveRejection() {
        #expect(throws: (any Error).self) {
            try SelectorValidator.validate("JAVASCRIPT:void(0)")
        }
    }

    @Test func rejectsSetTimeout() {
        #expect(throws: (any Error).self) {
            try SelectorValidator.validate("setTimeout(fn)")
        }
    }

    @Test func rejectsWindowLocation() {
        #expect(throws: (any Error).self) {
            try SelectorValidator.validate("window.location.href")
        }
    }
}
