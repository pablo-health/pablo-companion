import CompanionSessionCore
import Foundation
@testable import Pablo
import Testing

/// Stands in for the network: returns a canned check, records what was asked.
@MainActor
private final class FakeConsentService: RecordingConsentService {
    var check: RecordingConsentCheck?
    var checkError: Error?
    var saveError: Error?
    private(set) var checkedAppointments: [String] = []
    private(set) var checkedModalities: [AiConsentModality?] = []
    private(set) var recordedPatients: [String] = []
    private(set) var recordedAnswers: [AiConsentAnswer] = []

    func checkRecordingConsent(
        appointmentId: String,
        patientId _: String?,
        modality: AiConsentModality?
    ) async throws -> RecordingConsentCheck {
        checkedAppointments.append(appointmentId)
        checkedModalities.append(modality)
        if let checkError { throw checkError }
        guard let check else { throw URLError(.badServerResponse) }
        return check
    }

    func recordConsent(_ answer: AiConsentAnswer, patientId: String) async throws {
        if let saveError { throw saveError }
        recordedPatients.append(patientId)
        recordedAnswers.append(answer)
    }
}

private func check(_ consent: RecordingConsent, asks: Bool = true) -> RecordingConsentCheck {
    RecordingConsentCheck(consent: consent, asksClients: asks, audioRetentionDays: 365, patientId: asks ? "pat-1" : nil)
}

@MainActor
@Suite("RecordingConsentViewModel")
struct RecordingConsentViewModelTests {
    @Test("Setting off: clear, and no script is offered")
    func settingOff() async {
        let service = FakeConsentService()
        service.check = check(.clear, asks: false)
        let vm = RecordingConsentViewModel()

        let consent = await vm.check(appointmentId: "appt-1", patientId: nil, service: service)

        #expect(consent == .clear)
        #expect(vm.consent == .clear)
        #expect(vm.scriptRetentionDays == nil)
    }

    @Test("Declined: the prompt shows the decline with its date")
    func declined() async {
        let service = FakeConsentService()
        service.check = check(.declined(on: "2026-09-01"))
        let vm = RecordingConsentViewModel()

        let consent = await vm.check(appointmentId: "appt-1", patientId: nil, service: service)

        #expect(consent == .declined(on: "2026-09-01"))
        #expect(vm.consent == .declined(on: "2026-09-01"))
        #expect(service.checkedAppointments == ["appt-1"])
    }

    @Test("In person with nothing on file offers Ask now; Ask now starts asking on the recording, in person")
    func inPersonAskNow() async {
        let service = FakeConsentService()
        service.check = check(.askOnRecording(.inPerson))
        let vm = RecordingConsentViewModel()

        let consent = await vm.check(appointmentId: "appt-1", patientId: "pat-1", modality: .inPerson, service: service)

        #expect(consent == .askOnRecording(.inPerson))
        #expect(!vm.consent.startsAskingOnRecording)

        vm.askNow()

        #expect(vm.consent == .askingOnRecording(.inPerson))
        #expect(vm.consent.askingModality == .inPerson)
        #expect(vm.patientId == "pat-1")
        #expect(vm.scriptRetentionDays == 365)
        // Nothing is written before the client answers on the recording:
        // there is no pre-selected "agreed".
        #expect(service.recordedAnswers.isEmpty)
    }

    @Test("Telehealth with nothing on file offers Ask now; Ask now starts asking on the recording")
    func telehealthAskNow() async {
        let service = FakeConsentService()
        service.check = check(.askOnRecording(.telehealth))
        let vm = RecordingConsentViewModel()

        let consent = await vm.check(appointmentId: "appt-1", patientId: "pat-1", modality: .telehealth, service: service)

        #expect(consent == .askOnRecording(.telehealth))
        #expect(service.checkedModalities == [.telehealth])
        #expect(!vm.consent.startsAskingOnRecording)

        vm.askNow()

        #expect(vm.consent == .askingOnRecording(.telehealth))
        #expect(vm.consent.startsAskingOnRecording)
        #expect(vm.patientId == "pat-1")
        #expect(vm.scriptRetentionDays == 365)
        // Nothing is written before the client answers on the recording.
        #expect(service.recordedAnswers.isEmpty)
    }

    @Test("Ask now does nothing when there is nothing to ask")
    func askNowWhenClear() async {
        let service = FakeConsentService()
        service.check = check(.clear)
        let vm = RecordingConsentViewModel()
        await vm.check(appointmentId: "appt-1", patientId: nil, service: service)

        vm.askNow()

        #expect(vm.consent == .clear)
        #expect(!vm.consent.startsAskingOnRecording)
    }

    @Test("Don't record writes nothing: the prompt never calls the service on its own")
    func dontRecordWritesNothing() async {
        let service = FakeConsentService()
        service.check = check(.askOnRecording(.inPerson))
        let vm = RecordingConsentViewModel()
        await vm.check(appointmentId: "appt-1", patientId: nil, service: service)

        // "Don't record" dismisses straight from the view; nothing here records.
        vm.reset()

        #expect(service.recordedPatients.isEmpty)
        #expect(vm.consent == .clear)
    }

    @Test("A web 'Record anyway' does not clear a telehealth client nobody has asked")
    func webRecordAnywayTelehealth() async {
        let service = FakeConsentService()
        service.check = check(.askOnRecording(.telehealth))
        let vm = RecordingConsentViewModel()

        let consent = await vm.check(appointmentId: "appt-1", patientId: nil, webAlreadyAsked: true, service: service)

        #expect(consent == .askOnRecording(.telehealth))
    }

    @Test(
        "A web 'Ask now' hand-off starts asking on the recording without offering it again",
        arguments: [AiConsentModality.telehealth, .inPerson]
    )
    func webAskNow(modality: AiConsentModality) async {
        let service = FakeConsentService()
        service.check = check(.askOnRecording(modality))
        let vm = RecordingConsentViewModel()

        let consent = await vm.check(
            appointmentId: "appt-1",
            patientId: nil,
            modality: modality,
            webAskingOnRecording: true,
            service: service
        )

        #expect(consent == .askingOnRecording(modality))
        #expect(vm.consent.askingModality == modality)
    }

    @Test("A server consent-needed refusal turns into Ask now / Don't record")
    func serverConsentNeeded() async {
        let service = FakeConsentService()
        service.check = check(.clear)
        let vm = RecordingConsentViewModel()
        await vm.check(appointmentId: "appt-1", patientId: nil, service: service)

        vm.showConsentNeeded()

        #expect(vm.consent == .askOnRecording(.telehealth))
        #expect(vm.patientId == "pat-1")
        #expect(vm.scriptRetentionDays == 365)
    }

    @Test("With no earlier read, a consent-needed refusal offers no script for an unknown window")
    func serverConsentNeededUnread() {
        let vm = RecordingConsentViewModel()

        vm.showConsentNeeded()

        #expect(vm.consent == .askOnRecording(.telehealth))
        #expect(vm.scriptRetentionDays == nil)
    }

    @Test("An in-person hand-off the web already asked about arms without asking again")
    func webAlreadyAsked() async {
        let service = FakeConsentService()
        service.check = check(.askOnRecording(.inPerson))
        let vm = RecordingConsentViewModel()

        let consent = await vm.check(appointmentId: "appt-1", patientId: nil, webAlreadyAsked: true, service: service)

        #expect(consent == .clear)
        #expect(vm.consent == .clear)
        #expect(service.checkedAppointments == ["appt-1"])
    }

    @Test("A hand-off without the web's answer still asks")
    func webDidNotAsk() async {
        let service = FakeConsentService()
        service.check = check(.askOnRecording(.inPerson))
        let vm = RecordingConsentViewModel()

        let consent = await vm.check(appointmentId: "appt-1", patientId: nil, service: service)

        #expect(consent == .askOnRecording(.inPerson))
        #expect(vm.consent == .askOnRecording(.inPerson))
    }

    @Test("A declined client is still refused when the web already asked")
    func webAlreadyAskedDeclined() async {
        let service = FakeConsentService()
        service.check = check(.declined(on: "2026-09-01"))
        let vm = RecordingConsentViewModel()

        let consent = await vm.check(appointmentId: "appt-1", patientId: nil, webAlreadyAsked: true, service: service)

        #expect(consent == .declined(on: "2026-09-01"))
        #expect(vm.consent == .declined(on: "2026-09-01"))
    }

    @Test("A failed read does not block: it reads as clear and the server still gates")
    func readFailure() async {
        let service = FakeConsentService()
        service.checkError = URLError(.timedOut)
        let vm = RecordingConsentViewModel()

        let consent = await vm.check(appointmentId: "appt-1", patientId: nil, service: service)

        #expect(consent == .clear)
        #expect(vm.phase == .idle)
    }

    @Test("A server refusal turns into the declined prompt")
    func serverRefusal() async {
        let service = FakeConsentService()
        service.check = check(.clear)
        let vm = RecordingConsentViewModel()
        await vm.check(appointmentId: "appt-1", patientId: nil, service: service)

        vm.showRefusal(declinedOn: "2026-09-01")

        #expect(vm.consent == .declined(on: "2026-09-01"))
        #expect(vm.patientId == "pat-1")
    }
}

@MainActor
@Suite("Declined refusal mapping")
struct DeclinedRefusalMappingTests {
    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://backend.test/api/appointments/a/start-session")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }

    @Test("403 CLIENT_DECLINED_AI_NOTES becomes clientDeclinedAiNotes with its date")
    func declinedMapped() {
        let body = Data("""
        {"error": {"code": "CLIENT_DECLINED_AI_NOTES", "message": "This client declined AI-assisted notes.",
                   "details": {"declined_on": "2026-09-01"}}}
        """.utf8)
        #expect {
            try APIClient().mapHTTPErrors(data: body, response: response(403))
        } throws: { error in
            guard case let PabloError.clientDeclinedAiNotes(on) = error else { return false }
            return on == "2026-09-01"
        }
    }

    @Test("403 CLIENT_AI_CONSENT_NEEDED becomes clientAiConsentNeeded, not a generic error")
    func consentNeededMapped() {
        let body = Data(#"""
        {"error": {"code": "CLIENT_AI_CONSENT_NEEDED",
                   "message": "Ask this client about AI-assisted notes when recording starts."}}
        """#.utf8)
        #expect {
            try APIClient().mapHTTPErrors(data: body, response: response(403))
        } throws: { error in
            guard case PabloError.clientAiConsentNeeded = error else { return false }
            return true
        }
    }

    @Test("Any other 403 stays forbidden")
    func otherForbidden() {
        let body = Data(#"{"error": {"code": "SUBSCRIPTION_REQUIRED", "message": "x"}}"#.utf8)
        #expect {
            try APIClient().mapHTTPErrors(data: body, response: response(403))
        } throws: { error in
            guard case PabloError.forbidden = error else { return false }
            return true
        }
    }

    @Test("The declined message names the day")
    func message() {
        let enUS = Locale(identifier: "en_US")
        #expect(RecordingConsentCopy.declined(on: "2026-09-01", locale: enUS)
            == "This client declined AI-assisted notes on Sep 1, 2026.")
        #expect(RecordingConsentCopy.declined(on: "") == "This client declined AI-assisted notes.")
    }
}

@Suite("Launch redemption carries the web's answer")
struct LaunchRedemptionDecodingTests {
    @Test("The web's 'Record anyway' comes through the redeem response")
    func prompted() throws {
        let body = Data(#"""
        {"appointment_id": "appt-1", "patient_name": null, "video_url": null,
         "session_id": null, "ai_consent_prompted": true}
        """#.utf8)
        let redemption = try JSONDecoder().decode(LaunchRedemption.self, from: body)
        #expect(redemption.aiConsentPrompted)
    }

    @Test("A server without the field reads as not asked")
    func olderServer() throws {
        let body = Data(#"{"appointment_id": "appt-1", "video_url": null, "session_id": null}"#.utf8)
        let redemption = try JSONDecoder().decode(LaunchRedemption.self, from: body)
        #expect(!redemption.aiConsentPrompted)
        #expect(!redemption.askConsentOnRecording)
        #expect(redemption.modality == nil)
    }

    @Test("The redeem says telehealth, and whether the web chose Ask now")
    func telehealthAskNow() throws {
        let body = Data(#"""
        {"appointment_id": "appt-1", "patient_name": null, "video_url": "https://video.example/r",
         "session_id": null, "ai_consent_prompted": false, "ask_consent_on_recording": true,
         "telehealth": true}
        """#.utf8)
        let redemption = try JSONDecoder().decode(LaunchRedemption.self, from: body)
        #expect(redemption.askConsentOnRecording)
        #expect(redemption.modality == .telehealth)
    }
}

@Suite("Appointments say whether they are telehealth")
struct AppointmentTelehealthTests {
    private func appointment(_ extra: String) throws -> Appointment {
        let json = """
        {"id": "a", "patient_id": "p", "title": "t", "start_at": "s", "end_at": "e",
         "duration_minutes": 50, "status": "scheduled", "created_at": "c"\(extra)}
        """
        return try JSONDecoder().decode(Appointment.self, from: Data(json.utf8))
    }

    @Test("A video link, a video service or a telehealth place is telehealth")
    func telehealth() throws {
        #expect(try appointment(#", "video_link": "https://video.example/r""#).isTelehealth)
        #expect(try appointment(#", "provider": "doxy_me""#).isTelehealth)
        #expect(try appointment(#", "place_of_service": "10""#).isTelehealth)
    }

    @Test("The office, or nothing set, is in person")
    func inPerson() throws {
        #expect(try !appointment(#", "place_of_service": "11""#).isTelehealth)
        #expect(try !appointment("").isTelehealth)
    }
}

@MainActor
@Suite("AskOnRecordingViewModel")
struct AskOnRecordingViewModelTests {
    @Test("An answer on the recording is saved as telehealth, with who answered and where")
    func recordsTelehealthAnswer() async {
        let service = FakeConsentService()
        let vm = AskOnRecordingViewModel()
        vm.begin(sessionId: "s1", patientId: "pat-1", retentionDays: 0, modality: .telehealth)
        vm.giver = .guardian
        vm.location = " At home "

        let saved = await vm.record(decision: AiConsentEntry.consented, service: service)

        #expect(saved)
        #expect(service.recordedPatients == ["pat-1"])
        #expect(service.recordedAnswers.first?.body == [
            "decision": "consented",
            "modality": "telehealth",
            "consented_by": "guardian",
            "client_stated_location": "At home",
        ])
    }

    @Test("In person, the answer is saved as given in person, with who answered and no place")
    func recordsInPersonAnswer() async {
        let service = FakeConsentService()
        let vm = AskOnRecordingViewModel()
        vm.begin(sessionId: "s1", patientId: "pat-1", retentionDays: 365, modality: .inPerson)
        #expect(!vm.asksLocation)
        vm.giver = .parent
        // Left over from nowhere the panel shows; never sent in person.
        vm.location = "Office"

        let saved = await vm.record(decision: AiConsentEntry.consented, service: service)

        #expect(saved)
        #expect(service.recordedPatients == ["pat-1"])
        #expect(service.recordedAnswers.first?.body == [
            "decision": "consented",
            "modality": "in_person",
            "consented_by": "parent",
        ])
    }

    @Test("In person, a decline on the recording is saved as given in person")
    func recordsInPersonDecline() async {
        let service = FakeConsentService()
        let vm = AskOnRecordingViewModel()
        vm.begin(sessionId: "s1", patientId: "pat-1", retentionDays: 365, modality: .inPerson)

        _ = await vm.record(decision: AiConsentEntry.declined, service: service)

        #expect(service.recordedAnswers.first?.body == [
            "decision": "declined",
            "modality": "in_person",
            "consented_by": "client",
        ])
    }

    @Test("Telehealth asks where the client is")
    func telehealthAsksLocation() {
        let vm = AskOnRecordingViewModel()
        vm.begin(sessionId: "s1", patientId: "pat-1", retentionDays: 0, modality: .telehealth)
        #expect(vm.asksLocation)
    }

    @Test("With nothing asked, there is no answer to send")
    func noAskNoAnswer() async {
        let service = FakeConsentService()
        let vm = AskOnRecordingViewModel()
        #expect(vm.answer(decision: AiConsentEntry.consented) == nil)
        let saved = await vm.record(decision: AiConsentEntry.consented, service: service)
        #expect(!saved)
        #expect(service.recordedAnswers.isEmpty)
    }

    @Test("A decline on the recording is saved the same way")
    func recordsDecline() async {
        let service = FakeConsentService()
        let vm = AskOnRecordingViewModel()
        vm.begin(sessionId: "s1", patientId: "pat-1", retentionDays: 90, modality: .telehealth)

        _ = await vm.record(decision: AiConsentEntry.declined, service: service)

        #expect(service.recordedAnswers.first?.body == [
            "decision": "declined",
            "modality": "telehealth",
            "consented_by": "client",
        ])
    }

    @Test("Without a place, none is sent")
    func noPlace() async {
        let service = FakeConsentService()
        let vm = AskOnRecordingViewModel()
        vm.begin(sessionId: "s1", patientId: "pat-1", retentionDays: 90, modality: .telehealth)

        _ = await vm.record(decision: AiConsentEntry.consented, service: service)

        #expect(service.recordedAnswers.first?.body == [
            "decision": "consented",
            "modality": "telehealth",
            "consented_by": "client",
        ])
    }

    @Test("A failed save keeps the panel with a message")
    func saveFails() async {
        let service = FakeConsentService()
        service.saveError = URLError(.notConnectedToInternet)
        let vm = AskOnRecordingViewModel()
        vm.begin(sessionId: "s1", patientId: "pat-1", retentionDays: 90, modality: .telehealth)

        let saved = await vm.record(decision: AiConsentEntry.consented, service: service)

        #expect(!saved)
        #expect(vm.ask != nil)
        #expect(vm.saveError == RecordingConsentCopy.saveFailed)
        #expect(!vm.isSaving)
    }

    @Test("With no client known, nothing is written")
    func unknownClient() async {
        let service = FakeConsentService()
        let vm = AskOnRecordingViewModel()
        vm.begin(sessionId: "s1", patientId: nil, retentionDays: nil, modality: .telehealth)

        let saved = await vm.record(decision: AiConsentEntry.consented, service: service)

        #expect(!saved)
        #expect(service.recordedAnswers.isEmpty)
    }

    @Test("Each ask starts fresh")
    func beginResets() {
        let vm = AskOnRecordingViewModel()
        vm.begin(sessionId: "s1", patientId: "pat-1", retentionDays: 90, modality: .telehealth)
        vm.giver = .parent
        vm.location = "Car"
        vm.markRecordingDeleted()
        #expect(vm.recordingDeleted)

        vm.begin(sessionId: "s2", patientId: "pat-2", retentionDays: 90, modality: .telehealth)

        #expect(vm.giver == .client)
        #expect(vm.location.isEmpty)
        #expect(!vm.recordingDeleted)
        #expect(vm.ask?.sessionId == "s2")
    }
}
