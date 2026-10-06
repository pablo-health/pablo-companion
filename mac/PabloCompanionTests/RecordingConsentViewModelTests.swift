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
    private(set) var recordedPatients: [String] = []

    func checkRecordingConsent(appointmentId: String, patientId _: String?) async throws -> RecordingConsentCheck {
        checkedAppointments.append(appointmentId)
        if let checkError { throw checkError }
        guard let check else { throw URLError(.badServerResponse) }
        return check
    }

    func recordAgreedToday(patientId: String) async throws {
        if let saveError { throw saveError }
        recordedPatients.append(patientId)
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

    @Test("Not asked: agreed today records consent for the client, then reads clear")
    func agreedToday() async {
        let service = FakeConsentService()
        service.check = check(.notAsked)
        let vm = RecordingConsentViewModel()
        await vm.check(appointmentId: "appt-1", patientId: nil, service: service)
        #expect(vm.consent == .notAsked)
        #expect(vm.scriptRetentionDays == 365)

        let saved = await vm.recordAgreedToday(service: service)

        #expect(saved)
        #expect(service.recordedPatients == ["pat-1"])
        #expect(vm.consent == .clear)
        #expect(vm.saveError == nil)
    }

    @Test("A failed save keeps the prompt up with a message, and records nothing")
    func agreedTodayFails() async {
        let service = FakeConsentService()
        service.check = check(.notAsked)
        service.saveError = URLError(.notConnectedToInternet)
        let vm = RecordingConsentViewModel()
        await vm.check(appointmentId: "appt-1", patientId: nil, service: service)

        let saved = await vm.recordAgreedToday(service: service)

        #expect(!saved)
        #expect(vm.consent == .notAsked)
        #expect(vm.saveError == RecordingConsentCopy.saveFailed)
        #expect(!vm.isSaving)
    }

    @Test("Record anyway writes nothing: the prompt never calls the service on its own")
    func recordAnywayWritesNothing() async {
        let service = FakeConsentService()
        service.check = check(.notAsked)
        let vm = RecordingConsentViewModel()
        await vm.check(appointmentId: "appt-1", patientId: nil, service: service)

        // "Record anyway" arms straight from the view; nothing here records.
        vm.reset()

        #expect(service.recordedPatients.isEmpty)
        #expect(vm.consent == .clear)
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
