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

    @Test("A hand-off the web already asked about does not ask again")
    func handedOffAfterWebAsked() {
        #expect(RecordingConsent.notAsked.handedOff(webAlreadyAsked: true) == .clear)
        #expect(RecordingConsent.clear.handedOff(webAlreadyAsked: true) == .clear)
    }

    @Test("A decline still stops a hand-off the web already asked about")
    func handedOffDeclined() {
        #expect(RecordingConsent.declined(on: "2026-09-01").handedOff(webAlreadyAsked: true)
            == .declined(on: "2026-09-01"))
    }

    @Test("Without the web's answer, a hand-off still asks")
    func handedOffWithoutWebAnswer() {
        #expect(RecordingConsent.notAsked.handedOff(webAlreadyAsked: false) == .notAsked)
        #expect(RecordingConsent.declined(on: "2026-09-01").handedOff(webAlreadyAsked: false)
            == .declined(on: "2026-09-01"))
        #expect(RecordingConsent.clear.handedOff(webAlreadyAsked: false) == .clear)
    }

    /// The gate decision across where the session is × what is on file.
    @Test(
        "Where the session is × what is on file",
        arguments: [
            (false, nil, RecordingConsent.notAsked),
            (true, nil, .askOnRecording),
            (false, "consented", .clear),
            (true, "consented", .clear),
            (false, "declined", .declined(on: "2026-09-01")),
            (true, "declined", .declined(on: "2026-09-01")),
        ] as [(Bool, String?, RecordingConsent)]
    )
    func gate(telehealth: Bool, onFile: String?, expected: RecordingConsent) {
        let current = onFile.map { AiConsentEntry(decision: $0, effectiveOn: "2026-09-01") }
        #expect(RecordingConsent.evaluate(asksClients: true, current: current, telehealth: telehealth) == expected)
    }

    @Test("Setting off is clear for telehealth too")
    func settingOffTelehealth() {
        #expect(RecordingConsent.evaluate(asksClients: false, current: nil, telehealth: true) == .clear)
    }

    @Test("A web 'record anyway' never clears a telehealth start with nothing on file")
    func webRecordAnywayTelehealth() {
        #expect(RecordingConsent.askOnRecording.handedOff(webAlreadyAsked: true) == .askOnRecording)
    }

    @Test("A web 'Ask now' starts asking on the recording without offering it again")
    func webAskNow() {
        #expect(RecordingConsent.askOnRecording.handedOff(webAlreadyAsked: false, webAskingOnRecording: true)
            == .askingOnRecording)
        #expect(RecordingConsent.askingOnRecording.startsAskingOnRecording)
        // Answered since the web asked: nothing to ask on the recording.
        #expect(RecordingConsent.clear.handedOff(webAlreadyAsked: false, webAskingOnRecording: true) == .clear)
        #expect(RecordingConsent.declined(on: "2026-09-01")
            .handedOff(webAlreadyAsked: false, webAskingOnRecording: true) == .declined(on: "2026-09-01"))
        #expect(!RecordingConsent.clear.startsAskingOnRecording)
        #expect(!RecordingConsent.askOnRecording.startsAskingOnRecording)
    }

    @Test("The server's consent-needed refusal is recognized")
    func consentNeededParsed() {
        let body = Data("""
        {"error": {"code": "CLIENT_AI_CONSENT_NEEDED",
                   "message": "Ask this client about AI-assisted notes when recording starts."}}
        """.utf8)
        #expect(RecordingConsent.isConsentNeeded(statusCode: 403, body: body))
        #expect(!RecordingConsent.isConsentNeeded(statusCode: 409, body: body))
        let declined = Data(#"{"error": {"code": "CLIENT_DECLINED_AI_NOTES", "message": "x"}}"#.utf8)
        #expect(!RecordingConsent.isConsentNeeded(statusCode: 403, body: declined))
        #expect(RecordingConsent.declinedOn(statusCode: 403, body: body) == nil)
    }

    @Test("Telehealth is a video service, a video link, or a telehealth place")
    func telehealth() {
        #expect(Telehealth.isTelehealth(provider: "doxy_me", videoLink: nil, placeOfService: nil))
        #expect(Telehealth.isTelehealth(provider: nil, videoLink: "https://video.example/room", placeOfService: nil))
        #expect(Telehealth.isTelehealth(provider: nil, videoLink: nil, placeOfService: "10"))
        #expect(Telehealth.isTelehealth(provider: nil, videoLink: nil, placeOfService: "02"))
        #expect(!Telehealth.isTelehealth(provider: nil, videoLink: nil, placeOfService: "11"))
        #expect(!Telehealth.isTelehealth(provider: nil, videoLink: nil, placeOfService: nil))
        #expect(!Telehealth.isTelehealth(provider: "", videoLink: "", placeOfService: nil))
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

    @Test("The script names the practice's retention window, read once recording has started")
    func lines() {
        // Word for word the web app's script (AiNotesConsentScript.consentScript).
        #expect(ConsentScript.lines(retentionDays: 365) == [
            "I've started recording our session.",
            "The recording is turned into a written transcript, and an AI tool uses it to draft my notes. "
                + "I read and correct every note myself.",
            "The audio is kept for up to 1 year.",
            "You can say no, now or at any time.",
            "Is that all right with you?",
        ])
        #expect(ConsentScript.lines(retentionDays: 90)[2] == "The audio is kept for up to 90 days.")
    }

    @Test("At 0 days the script says the audio is deleted once the note is signed")
    func deletedOnSigning() {
        let lines = ConsentScript.lines(retentionDays: 0)
        #expect(lines.count == 5)
        #expect(lines[2] == "The audio is deleted once your note is signed.")
        #expect(!lines.joined().contains("0 days"))
    }
}

@Suite("Consent request bodies")
struct ConsentRequestBodyTests {
    @Test("'Agreed today' in the room says in person and who answered")
    func agreedInPerson() {
        #expect(AiConsentAnswer.agreedInPerson(by: .parent).body == [
            "decision": "consented",
            "modality": "in_person",
            "consented_by": "parent",
        ])
    }

    @Test("A telehealth answer carries where the client said they were, trimmed")
    func telehealthWithPlace() {
        let answer = AiConsentAnswer(
            decision: "consented",
            modality: .telehealth,
            consentedBy: .client,
            clientStatedLocation: "  At home  "
        )
        #expect(answer.body == [
            "decision": "consented",
            "modality": "telehealth",
            "consented_by": "client",
            "client_stated_location": "At home",
        ])
    }

    @Test("A blank place, or one given in person, is not sent")
    func noPlace() {
        let blank = AiConsentAnswer(
            decision: "declined",
            modality: .telehealth,
            consentedBy: .guardian,
            clientStatedLocation: "  "
        )
        #expect(blank.body["client_stated_location"] == nil)
        #expect(blank.body["consented_by"] == "guardian")
        let inPerson = AiConsentAnswer(
            decision: "consented",
            modality: .inPerson,
            consentedBy: .client,
            clientStatedLocation: "Office"
        )
        #expect(inPerson.body["client_stated_location"] == nil)
    }

    @Test("A place longer than the server keeps is cut to fit")
    func longPlace() {
        let answer = AiConsentAnswer(
            decision: "consented",
            modality: .telehealth,
            consentedBy: .client,
            clientStatedLocation: String(repeating: "a", count: 300)
        )
        #expect(answer.body["client_stated_location"]?.count == AiConsentAnswer.locationMaxLength)
    }

    @Test("A start asking on the recording says so; any other start sends no body")
    func startSessionBody() throws {
        #expect(RecordingConsentClient.startSessionBody(askingConsentOnRecording: false) == nil)
        let data = try #require(RecordingConsentClient.startSessionBody(askingConsentOnRecording: true))
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Bool])
        #expect(body == ["asking_consent_on_recording": true])
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

        #expect(check == RecordingConsentCheck(
            consent: .clear,
            asksClients: false,
            audioRetentionDays: 30,
            patientId: nil
        ))
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

    @Test("A hand-off reads telehealth from the appointment when the redeem did not say")
    func telehealthFromAppointment() async throws {
        let recorder = ConsentStubProtocol.install()
        defer { ConsentStubProtocol.reset() }
        recorder.enqueue(status: 200, json: Self.settingOn)
        recorder.enqueue(
            status: 200,
            json: #"{"id": "appt-1", "patient_id": "pat-9", "video_link": "https://video.example/r"}"#
        )
        recorder.enqueue(status: 200, json: Self.noAnswer)

        let check = try await makeClient().check(appointmentId: "appt-1")

        #expect(check.consent == .askOnRecording)
    }

    @Test("The caller's telehealth answer wins over the appointment's")
    func telehealthFromCaller() async throws {
        let recorder = ConsentStubProtocol.install()
        defer { ConsentStubProtocol.reset() }
        recorder.enqueue(status: 200, json: Self.settingOn)
        recorder.enqueue(status: 200, json: Self.noAnswer)

        let check = try await makeClient().check(appointmentId: "appt-1", patientId: "pat-9", modality: .telehealth)

        #expect(check.consent == .askOnRecording)
        #expect(recorder.captured.count == 2)
    }

    @Test("A telehealth answer posts how it was given, with no date")
    func recordTelehealthAnswer() async throws {
        let recorder = ConsentStubProtocol.install()
        defer { ConsentStubProtocol.reset() }
        recorder.enqueue(status: 201, json: Self.noAnswer)

        let answer = AiConsentAnswer(
            decision: "consented",
            modality: .telehealth,
            consentedBy: .guardian,
            clientStatedLocation: "At home"
        )
        try await makeClient().record(answer, patientId: "pat-9")

        let request = try #require(recorder.captured.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/patients/pat-9/ai-consent")
        let body = try #require(JSONSerialization.jsonObject(with: request.capturedBody) as? [String: String])
        #expect(body == [
            "decision": "consented",
            "modality": "telehealth",
            "consented_by": "guardian",
            "client_stated_location": "At home",
        ])
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

        try await makeClient().record(.agreedInPerson(by: .client), patientId: "pat-9")

        let request = try #require(recorder.captured.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/patients/pat-9/ai-consent")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(JSONSerialization.jsonObject(with: request.capturedBody) as? [String: String])
        #expect(body == ["decision": "consented", "modality": "in_person", "consented_by": "client"])
    }

    @Test("A failed request surfaces its status and code")
    func failure() async throws {
        let recorder = ConsentStubProtocol.install()
        defer { ConsentStubProtocol.reset() }
        recorder.enqueue(status: 401, json: #"{"error": {"code": "IDLE_TIMEOUT", "message": "x"}}"#)

        await #expect(throws: ConsentRequestError(statusCode: 401, code: "IDLE_TIMEOUT")) {
            try await makeClient().record(.agreedInPerson(by: .client), patientId: "pat-9")
        }
    }
}
