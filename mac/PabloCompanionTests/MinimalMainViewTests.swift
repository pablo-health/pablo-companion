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

    @Test func keepsTheRecordingAppointmentAfterItsScheduledEnd() throws {
        // Regression: once the scheduled end passed, the `end >= now` filter
        // dropped the appointment and the window flipped to "all caught up" —
        // while still recording, with no End Session button left anywhere.
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-03T15:51:00Z"))
        let recording = makeAppointment(
            startAt: "2026-09-03T15:00:00Z",
            endAt: "2026-09-03T15:50:00Z",
            sessionId: "session-1"
        )

        let selected = MinimalMainView.nextAppointment(
            in: [recording], now: now, activeSessionId: "session-1"
        )

        #expect(selected?.id == recording.id)
    }

    @Test func holdsAnAppointmentAtItsExactEndInstant() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-03T15:50:00Z"))
        let appointment = makeAppointment(
            startAt: "2026-09-03T15:00:00Z",
            endAt: "2026-09-03T15:50:00Z"
        )

        #expect(MinimalMainView.nextAppointment(in: [appointment], now: now)?.id == appointment.id)
    }

    @Test func keepsTheRecordingAppointmentLongPastItsEnd() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-03T17:30:00Z"))
        let recording = makeAppointment(
            startAt: "2026-09-03T15:00:00Z",
            endAt: "2026-09-03T15:50:00Z",
            sessionId: "session-1"
        )
        let upcoming = makeAppointment(
            id: "later",
            startAt: "2026-09-03T18:00:00Z",
            endAt: "2026-09-03T18:50:00Z"
        )

        let selected = MinimalMainView.nextAppointment(
            in: [recording, upcoming], now: now, activeSessionId: "session-1"
        )

        #expect(selected?.id == recording.id)
    }

    @Test func keepsTheRecordingAppointmentEvenIfCancelled() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-03T15:20:00Z"))
        let recording = makeAppointment(
            startAt: "2026-09-03T15:00:00Z",
            endAt: "2026-09-03T15:50:00Z",
            status: "cancelled",
            sessionId: "session-1"
        )

        let selected = MinimalMainView.nextAppointment(
            in: [recording], now: now, activeSessionId: "session-1"
        )

        #expect(selected?.id == recording.id)
    }

    @Test func advancesPastAnEndedAppointmentWhenNothingIsRecording() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-03T15:51:00Z"))
        let ended = makeAppointment(
            startAt: "2026-09-03T15:00:00Z",
            endAt: "2026-09-03T15:50:00Z",
            sessionId: "session-1"
        )
        let upcoming = makeAppointment(
            id: "later",
            startAt: "2026-09-03T16:00:00Z",
            endAt: "2026-09-03T16:50:00Z"
        )

        let selected = MinimalMainView.nextAppointment(
            in: [ended, upcoming], now: now, activeSessionId: nil
        )

        #expect(selected?.id == upcoming.id)
    }

    @Test func labelsAnOverrunningSessionAsRunningOver() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-03T16:05:00Z"))
        let recording = makeAppointment(
            startAt: "2026-09-03T15:00:00Z",
            endAt: "2026-09-03T15:50:00Z",
            sessionId: "session-1"
        )

        #expect(MinimalMainView.timingLabel(recording, now: now) == "RUNNING OVER")
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

    @Test func advancesPastASessionEndedBeforeItsScheduledEnd() throws {
        // Regression: ending a session early left the appointment selected
        // until its scheduled end — a dead "Session started" card instead of
        // the next appointment's Start Session.
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-03T15:20:00Z"))
        let endedEarly = makeAppointment(
            startAt: "2026-09-03T15:00:00Z",
            endAt: "2026-09-03T15:50:00Z",
            sessionId: "session-1"
        )
        let upcoming = makeAppointment(
            id: "later",
            startAt: "2026-09-03T16:00:00Z",
            endAt: "2026-09-03T16:50:00Z"
        )

        let selected = MinimalMainView.nextAppointment(
            in: [endedEarly, upcoming], now: now, activeSessionId: nil
        )

        #expect(selected?.id == upcoming.id)
    }

    @Test func showsNothingWhenTheLastSessionEndedEarly() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-03T15:20:00Z"))
        let endedEarly = makeAppointment(
            startAt: "2026-09-03T15:00:00Z",
            endAt: "2026-09-03T15:50:00Z",
            sessionId: "session-1"
        )

        #expect(MinimalMainView.nextAppointment(in: [endedEarly], now: now) == nil)
    }

    @Test func skipsAStartedSessionWhileAnotherIsRecording() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-03T15:20:00Z"))
        let earlier = makeAppointment(
            startAt: "2026-09-03T15:00:00Z",
            endAt: "2026-09-03T15:50:00Z",
            sessionId: "session-1"
        )
        let recording = makeAppointment(
            id: "recording",
            startAt: "2026-09-03T15:15:00Z",
            endAt: "2026-09-03T16:05:00Z",
            sessionId: "session-2"
        )

        let selected = MinimalMainView.nextAppointment(
            in: [earlier, recording], now: now, activeSessionId: "session-2"
        )

        #expect(selected?.id == recording.id)
    }

    @Test func pinsTheAppointmentBeingStarted() throws {
        // Starting refreshes the list (linking session_id) before
        // activeSessionId is set. Without the pin, the card would skip to the
        // next patient mid-start and offer Start Session on the wrong person.
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-03T14:58:00Z"))
        let starting = makeAppointment(
            startAt: "2026-09-03T15:00:00Z",
            endAt: "2026-09-03T15:50:00Z",
            sessionId: "session-1"
        )
        let upcoming = makeAppointment(
            id: "later",
            startAt: "2026-09-03T16:00:00Z",
            endAt: "2026-09-03T16:50:00Z"
        )

        let selected = MinimalMainView.nextAppointment(
            in: [starting, upcoming],
            now: now,
            activeSessionId: nil,
            startingAppointmentId: starting.id
        )

        #expect(selected?.id == starting.id)
    }

    @Test func keepsTheRecordingCardWhileAnotherSessionIsStarting() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-03T15:40:00Z"))
        let starting = makeAppointment(
            id: "starting",
            startAt: "2026-09-03T15:45:00Z",
            endAt: "2026-09-03T16:35:00Z"
        )
        let recording = makeAppointment(
            startAt: "2026-09-03T15:00:00Z",
            endAt: "2026-09-03T15:50:00Z",
            sessionId: "session-1"
        )

        let selected = MinimalMainView.nextAppointment(
            in: [starting, recording],
            now: now,
            activeSessionId: "session-1",
            startingAppointmentId: starting.id
        )

        #expect(selected?.id == recording.id)
    }

    @Test func offersStartingWhileTheSessionIsBeingCreated() {
        let appointment = makeAppointment(
            startAt: "2026-09-03T15:00:00Z",
            endAt: "2026-09-03T15:50:00Z"
        )

        #expect(
            MinimalMainView.action(
                for: appointment, activeSessionId: nil, startingAppointmentId: appointment.id
            ) == .starting
        )
    }

    @Test func offersStopOnceTheStartingSessionIsRecording() {
        let appointment = makeAppointment(
            startAt: "2026-09-03T15:00:00Z",
            endAt: "2026-09-03T15:50:00Z",
            sessionId: "session-1"
        )

        #expect(
            MinimalMainView.action(
                for: appointment, activeSessionId: "session-1", startingAppointmentId: appointment.id
            ) == .stopRecording
        )
    }

    // MARK: - Recording on another device (session_status)

    @Test func reportsASessionRecordingOnAnotherDevice() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-03T15:20:00Z"))
        let elsewhere = makeAppointment(
            startAt: "2026-09-03T15:00:00Z", endAt: "2026-09-03T15:50:00Z",
            sessionId: "session-1", sessionStatus: "in_progress"
        )
        let upcoming = makeAppointment(
            id: "later", startAt: "2026-09-03T16:00:00Z", endAt: "2026-09-03T16:50:00Z"
        )

        #expect(MinimalMainView.inProgressElsewhere(in: [elsewhere, upcoming], now: now)?.id == elsewhere.id)
        // A note, not the card: the next Start Session stays reachable.
        #expect(MinimalMainView.nextAppointment(in: [elsewhere, upcoming], now: now)?.id == upcoming.id)
    }

    @Test func theSessionRecordingHereIsNotElsewhere() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-03T15:20:00Z"))
        let recording = makeAppointment(
            startAt: "2026-09-03T15:00:00Z", endAt: "2026-09-03T15:50:00Z",
            sessionId: "session-1", sessionStatus: "in_progress"
        )

        #expect(MinimalMainView.inProgressElsewhere(in: [recording], now: now, activeSessionId: "session-1") == nil)
        #expect(
            MinimalMainView.inProgressElsewhere(in: [recording], now: now, startingAppointmentId: recording.id) == nil
        )
    }

    @Test func anEndedSessionIsNotElsewhere() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-03T15:20:00Z"))
        let ended = makeAppointment(
            startAt: "2026-09-03T15:00:00Z", endAt: "2026-09-03T15:50:00Z",
            sessionId: "session-1", sessionStatus: "recording_complete"
        )

        #expect(MinimalMainView.inProgressElsewhere(in: [ended], now: now) == nil)
    }

    @Test func aForgottenSessionStopsBeingReportedAfterItsSlot() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-03T17:00:00Z"))
        let forgotten = makeAppointment(
            startAt: "2026-09-03T15:00:00Z", endAt: "2026-09-03T15:50:00Z",
            sessionId: "session-1", sessionStatus: "in_progress"
        )

        #expect(MinimalMainView.inProgressElsewhere(in: [forgotten], now: now) == nil)
    }

    @Test func withoutSessionStatusNothingIsReportedElsewhere() throws {
        // Older backends: fall back to the session_id rule, report nothing.
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-03T15:20:00Z"))
        let started = makeAppointment(
            startAt: "2026-09-03T15:00:00Z", endAt: "2026-09-03T15:50:00Z", sessionId: "session-1"
        )

        #expect(MinimalMainView.inProgressElsewhere(in: [started], now: now) == nil)
        #expect(MinimalMainView.nextAppointment(in: [started], now: now) == nil)
    }

    // MARK: - Decoding session_status

    @Test func decodesSessionStatusWhenPresent() throws {
        let appointment = try Self.decode(sessionStatusJSON: #","session_status":"pending_review""#)
        #expect(appointment.sessionStatus == .pendingReview)
    }

    @Test func decodesWithoutSessionStatusFromAnOlderBackend() throws {
        let appointment = try Self.decode(sessionStatusJSON: "")
        #expect(appointment.sessionStatus == nil)
    }

    @Test func anUnknownSessionStatusDoesNotFailTheList() throws {
        let appointment = try Self.decode(sessionStatusJSON: #","session_status":"some_future_status""#)
        #expect(appointment.sessionStatusRaw == "some_future_status")
        #expect(appointment.sessionStatus == nil)
    }

    private static func decode(sessionStatusJSON: String) throws -> Appointment {
        let json = """
        {"id":"a","patient_id":"p","title":"t","start_at":"2026-09-03T15:00:00Z",
         "end_at":"2026-09-03T15:50:00Z","duration_minutes":50,"status":"confirmed",
         "session_id":"s","created_at":"2026-09-03T14:00:00Z"\(sessionStatusJSON)}
        """
        return try JSONDecoder().decode(Appointment.self, from: Data(json.utf8))
    }

    private func makeAppointment(
        id: String = "appointment",
        startAt: String,
        endAt: String,
        status: String = "scheduled",
        sessionId: String? = nil,
        sessionStatus: String? = nil
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
            updatedAt: nil,
            sessionStatusRaw: sessionStatus
        )
    }
}
