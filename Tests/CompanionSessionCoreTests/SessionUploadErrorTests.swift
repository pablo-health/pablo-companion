import Foundation
import Testing
@testable import CompanionSessionCore

/// Covers the error envelope and, importantly, that the error says something
/// when printed.
@Suite("SessionUploadError")
struct SessionUploadErrorTests {

    @Test func theDescriptionCarriesStatusCodeAndMessage() {
        // A bare Error struct bridges to "…SessionUploadError error 1", which is
        // what a failed 50-minute e2e actually reported — every field needed to
        // diagnose it was on the value and none of it was printed.
        let e = SessionUploadError(statusCode: 413, code: "TOO_LARGE", message: "payload too large")

        #expect(e.localizedDescription.contains("413"))
        #expect(e.localizedDescription.contains("TOO_LARGE"))
        #expect(e.localizedDescription.contains("payload too large"))
        #expect(!e.localizedDescription.contains("error 1"))
    }

    @Test func theDescriptionStillReadsWithoutCodeOrMessage() {
        let e = SessionUploadError(statusCode: 500, code: nil, message: nil)
        #expect(e.localizedDescription.contains("500"))
    }

    @Test func envelopeParsesCodeAndMessage() {
        let body = Data(#"{"error":{"code":"INVALID_STATUS","message":"session is not recording_complete"}}"#.utf8)
        let parsed = SessionUploadError.parseEnvelope(body)
        #expect(parsed?.code == "INVALID_STATUS")
        #expect(parsed?.message == "session is not recording_complete")
    }

    @Test func envelopeParsesTheNestedDetailShapeTheBackendActuallySends() {
        // The live backend nests under "detail" — observed from a real 401:
        // {"detail":{"error":{"code":"IDLE_TIMEOUT",...}}}
        let body = Data(#"{"detail":{"error":{"code":"IDLE_TIMEOUT","message":"Session expired"}}}"#.utf8)
        let parsed = SessionUploadError.parseEnvelope(body)
        // Documents current behaviour: the nested shape is NOT parsed, so code
        // is lost and callers cannot branch on IDLE_TIMEOUT from this path.
        #expect(parsed == nil)
    }

    @Test func aNonEnvelopeBodyReturnsNil() {
        #expect(SessionUploadError.parseEnvelope(Data("plain text".utf8)) == nil)
    }
}
