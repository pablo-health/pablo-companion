@testable import CompanionSessionCore
import Foundation
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("RecordingConsent decision")
struct RecordingConsentDecisionTests {
    @Test("Setting off is clear whatever the client said")
    func settingOff() {
        #expect(RecordingConsent.evaluate(asksClients: false, current: nil) == .clear)
        let declined = AiConsentEntry(decision: "declined", effectiveOn: "2026-09-01")
        #expect(RecordingConsent.evaluate(asksClients: false, current: declined) == .clear)
    }

    @Test("Setting on with no answer asks first")
    func notAsked() {
        #expect(RecordingConsent.evaluate(asksClients: true, current: nil) == .notAsked)
    }

    @Test("Setting on: consented is clear, declined stops with its date")
    func answered() {
        let agreed = AiConsentEntry(decision: "consented", effectiveOn: "2026-09-01")
        #expect(RecordingConsent.evaluate(asksClients: true, current: agreed) == .clear)
        let declined = AiConsentEntry(decision: "declined", effectiveOn: "2026-09-01")
        #expect(RecordingConsent.evaluate(asksClients: true, current: declined) == .declined(on: "2026-09-01"))
    }

    @Test("The server's declined refusal is recognized, with its date")
    func refusalParsed() {
        // The body the server sends for a refused start (403, standard envelope).
        let body = Data("""
        {"error": {"code": "CLIENT_DECLINED_AI_NOTES",
                   "message": "This client declined AI-assisted notes.",
                   "details": {"declined_on": "2026-09-01"}}}
        """.utf8)
        #expect(RecordingConsent.declinedOn(statusCode: 403, body: body) == "2026-09-01")
    }

    @Test("A refusal without a date still reads as declined")
    func refusalWithoutDate() {
        let body = Data(#"{"error": {"code": "CLIENT_DECLINED_AI_NOTES", "message": "x", "details": {}}}"#.utf8)
        #expect(RecordingConsent.declinedOn(statusCode: 403, body: body) == "")
    }

    @Test("Other refusals are not a decline")
    func otherRefusals() {
        let subscription = Data(#"{"error": {"code": "SUBSCRIPTION_REQUIRED", "message": "x"}}"#.utf8)
        #expect(RecordingConsent.declinedOn(statusCode: 403, body: subscription) == nil)
        let declinedCode = Data(#"{"error": {"code": "CLIENT_DECLINED_AI_NOTES"}}"#.utf8)
        #expect(RecordingConsent.declinedOn(statusCode: 409, body: declinedCode) == nil)
        #expect(RecordingConsent.declinedOn(statusCode: 403, body: Data("not json".utf8)) == nil)
    }

    @Test("Dates read the way a person says them")
    func displayDate() {
        let enUS = Locale(identifier: "en_US")
        #expect(RecordingConsent.displayDate("2026-10-05", locale: enUS) == "Oct 5, 2026")
        #expect(RecordingConsent.displayDate("garbage", locale: enUS) == "garbage")
    }
}

@Suite("ConsentScript")
struct ConsentScriptTests {
    @Test("Retention reads in years when it is whole years")
    func retention() {
        #expect(ConsentScript.retention(days: 365) == "1 year")
        #expect(ConsentScript.retention(days: 730) == "2 years")
        #expect(ConsentScript.retention(days: 90) == "90 days")
        #expect(ConsentScript.retention(days: 1) == "1 day")
    }

    @Test("The script names the practice's retention window")
    func lines() {
        let lines = ConsentScript.lines(retentionDays: 365)
        #expect(lines.count == 5)
        #expect(lines.contains("The audio is kept for up to 1 year."))
        #expect(lines.last == "Is that all right with you?")
    }
}

/// The upload suite's `StubURLProtocol` keeps its queue in static state, and
/// two `.serialized` suites still run in parallel with each other. This suite
/// gets its own stub class so the two never share a queue.
final class ConsentStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [(Int, Data)] = []
    nonisolated(unsafe) private static var recorder: Recorder?

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [CapturedRequest] = []
        var captured: [CapturedRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }

        func add(_ request: URLRequest) {
            lock.lock()
            requests.append(CapturedRequest(request))
            lock.unlock()
        }

        func enqueue(status: Int, json: String) {
            ConsentStubProtocol.lock.lock()
            ConsentStubProtocol.responses.append((status, Data(json.utf8)))
            ConsentStubProtocol.lock.unlock()
        }
    }

    static func install() -> Recorder {
        lock.lock()
        defer { lock.unlock() }
        responses = []
        let recorder = Recorder()
        self.recorder = recorder
        return recorder
    }

    static func reset() {
        lock.lock()
        responses = []
        recorder = nil
        lock.unlock()
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.recorder?.add(request)
        let canned = Self.responses.isEmpty ? nil : Self.responses.removeFirst()
        Self.lock.unlock()

        guard let (status, body) = canned, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("RecordingConsentClient", .serialized)
struct RecordingConsentClientTests {
    private func makeClient() -> RecordingConsentClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConsentStubProtocol.self]
        return RecordingConsentClient(
            baseURLString: "https://backend.test",
            token: { "test-bearer" },
            attachBinding: { request in
                request.setValue("proof-abc", forHTTPHeaderField: "DPoP")
                request.setValue("install-1", forHTTPHeaderField: "X-Install-ID")
            },
            session: URLSession(configuration: config)
        )
    }

    private static let settingOn = #"{"ask_clients_about_ai_notes": true, "audio_retention_days": 365, "can_change": false}"#
    private static let settingOff = #"{"ask_clients_about_ai_notes": false, "audio_retention_days": 30, "can_change": true}"#
    private static let noAnswer = #"{"current": null, "history": []}"#

    @Test("Setting off: one request, clear, and the client is never looked up")
    func settingOffSkipsClient() async throws {
        let recorder = ConsentStubProtocol.install()
        defer { ConsentStubProtocol.reset() }
        recorder.enqueue(status: 200, json: Self.settingOff)

        let check = try await makeClient().check(appointmentId: "appt-1")

        #expect(check == RecordingConsentCheck(consent: .clear, asksClients: false, audioRetentionDays: 30, patientId: nil))
        #expect(recorder.captured.count == 1)
        let request = try #require(recorder.captured.first)
        #expect(request.url?.path == "/api/users/me/practice/ai-notes-consent")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-bearer")
        #expect(request.value(forHTTPHeaderField: "DPoP") == "proof-abc")
    }

    @Test("A handoff with only an appointment id looks up its client, then the answer")
    func appointmentLookup() async throws {
        let recorder = ConsentStubProtocol.install()
        defer { ConsentStubProtocol.reset() }
        recorder.enqueue(status: 200, json: Self.settingOn)
        recorder.enqueue(status: 200, json: #"{"id": "appt-1", "patient_id": "pat-9", "title": "x"}"#)
        recorder.enqueue(status: 200, json: Self.noAnswer)

        let check = try await makeClient().check(appointmentId: "appt-1")

        #expect(check.consent == .notAsked)
        #expect(check.patientId == "pat-9")
        #expect(check.audioRetentionDays == 365)
        #expect(recorder.captured.map { $0.url?.path } == [
            "/api/users/me/practice/ai-notes-consent",
            "/api/appointments/appt-1",
            "/api/patients/pat-9/ai-consent",
        ])
    }

    @Test("A known client skips the appointment lookup; a decline carries its date")
    func knownClientDeclined() async throws {
        let recorder = ConsentStubProtocol.install()
        defer { ConsentStubProtocol.reset() }
        recorder.enqueue(status: 200, json: Self.settingOn)
        recorder.enqueue(status: 200, json: """
        {"current": {"id": "e1", "decision": "declined", "effective_on": "2026-09-01", "source": "clinician",
                     "recorded_by_name": "A", "recorded_at": "2026-09-01T10:00:00Z"},
         "history": []}
        """)

        let check = try await makeClient().check(appointmentId: "appt-1", patientId: "pat-9")

        #expect(check.consent == .declined(on: "2026-09-01"))
        #expect(recorder.captured.map { $0.url?.path } == [
            "/api/users/me/practice/ai-notes-consent",
            "/api/patients/pat-9/ai-consent",
        ])
    }

    @Test("An appointment with no client yet is clear")
    func unmatchedAppointment() async throws {
        let recorder = ConsentStubProtocol.install()
        defer { ConsentStubProtocol.reset() }
        recorder.enqueue(status: 200, json: Self.settingOn)
        recorder.enqueue(status: 200, json: #"{"id": "appt-1", "patient_id": ""}"#)

        let check = try await makeClient().check(appointmentId: "appt-1")

        #expect(check.consent == .clear)
        #expect(check.asksClients)
        #expect(recorder.captured.count == 2)
    }

    @Test("Agreed today posts a consent with no date")
    func recordAgreedToday() async throws {
        let recorder = ConsentStubProtocol.install()
        defer { ConsentStubProtocol.reset() }
        recorder.enqueue(status: 201, json: """
        {"current": {"id": "e2", "decision": "consented", "effective_on": "2026-10-05", "source": "clinician",
                     "recorded_by_name": "A", "recorded_at": "2026-10-05T10:00:00Z"},
         "history": []}
        """)

        try await makeClient().recordAgreedToday(patientId: "pat-9")

        let request = try #require(recorder.captured.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/patients/pat-9/ai-consent")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(JSONSerialization.jsonObject(with: request.capturedBody) as? [String: String])
        #expect(body == ["decision": "consented"])
    }

    @Test("A failed request surfaces its status and code")
    func failure() async throws {
        let recorder = ConsentStubProtocol.install()
        defer { ConsentStubProtocol.reset() }
        recorder.enqueue(status: 401, json: #"{"error": {"code": "IDLE_TIMEOUT", "message": "x"}}"#)

        await #expect(throws: ConsentRequestError(statusCode: 401, code: "IDLE_TIMEOUT")) {
            try await makeClient().recordAgreedToday(patientId: "pat-9")
        }
    }
}
