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

    private func makeAppointment(
        id: String = "appointment",
        startAt: String,
        endAt: String,
        status: String = "scheduled"
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
            sessionId: nil,
            createdAt: "2026-09-03T14:00:00Z",
            updatedAt: nil
        )
    }
}
