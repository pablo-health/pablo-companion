import Foundation
@testable import Pablo
import Testing

@MainActor
struct MinimalMainViewTests {
    @Test func selectsAppointmentStartingInFifteenMinutes() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-03T14:45:00Z"))
        let appointment = makeAppointment(
            startAt: "2026-09-03T15:00:00Z",
            endAt: "2026-09-03T15:50:00Z"
        )

        #expect(MinimalMainView.nextAppointment(in: [appointment], now: now)?.id == appointment.id)
    }

    @Test func keepsCurrentAppointmentVisibleUntilItEnds() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-03T15:15:00Z"))
        let appointment = makeAppointment(
            startAt: "2026-09-03T15:00:00Z",
            endAt: "2026-09-03T15:50:00Z"
        )

        #expect(MinimalMainView.nextAppointment(in: [appointment], now: now)?.id == appointment.id)
    }

    @Test func ignoresCancelledAppointments() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-03T14:45:00Z"))
        let cancelled = makeAppointment(
            startAt: "2026-09-03T15:00:00Z",
            endAt: "2026-09-03T15:50:00Z",
            status: "cancelled"
        )
        let active = makeAppointment(
            id: "active",
            startAt: "2026-09-03T16:00:00Z",
            endAt: "2026-09-03T16:50:00Z"
        )

        #expect(MinimalMainView.nextAppointment(in: [cancelled, active], now: now)?.id == active.id)
    }

    @Test func offersStartWhenNothingIsRecording() {
        // Regression: appointment.sessionId and activeSessionId are both nil on
        // a fresh launch. A bare `==` made that read as "recording in flight",
        // so the card showed Stop Recording — and the button no-opped.
        let appointment = makeAppointment(
            startAt: "2026-09-03T15:00:00Z",
            endAt: "2026-09-03T15:50:00Z"
        )

        #expect(
            MinimalMainView.action(for: appointment, activeSessionId: nil) == .start
        )
    }

    @Test func offersStartWhileAnotherSessionIsRecording() {
        let appointment = makeAppointment(
            startAt: "2026-09-03T15:00:00Z",
            endAt: "2026-09-03T15:50:00Z"
        )

        #expect(
            MinimalMainView.action(for: appointment, activeSessionId: "other-session") == .start
        )
    }

    @Test func offersStopForTheSessionBeingRecorded() {
        let appointment = makeAppointment(
            startAt: "2026-09-03T15:00:00Z",
            endAt: "2026-09-03T15:50:00Z",
            sessionId: "session-1"
        )

        #expect(
            MinimalMainView.action(for: appointment, activeSessionId: "session-1") == .stopRecording
        )
    }

    @Test func showsAlreadyStartedForASessionThisAppIsNotRecording() {
        let appointment = makeAppointment(
            startAt: "2026-09-03T15:00:00Z",
            endAt: "2026-09-03T15:50:00Z",
            sessionId: "session-1"
        )

        #expect(
            MinimalMainView.action(for: appointment, activeSessionId: nil) == .alreadyStarted
        )
        #expect(
            MinimalMainView.action(for: appointment, activeSessionId: "session-2") == .alreadyStarted
        )
    }

    private func makeAppointment(
        id: String = "appointment",
        startAt: String,
        endAt: String,
        status: String = "scheduled",
        sessionId: String? = nil
    ) -> Appointment {
        Appointment(
            id: id,
            patientId: "patient",
            title: "Initial consultation",
            startAt: startAt,
            endAt: endAt,
            durationMinutes: 50,
            status: status,
            sessionType: nil,
            videoLink: nil,
            videoPlatform: nil,
            notes: nil,
            icalSource: nil,
            ehrAppointmentUrl: nil,
            sessionId: sessionId,
            createdAt: "2026-09-03T14:00:00Z",
            updatedAt: nil
        )
    }
}
