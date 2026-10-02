import Foundation

/// Card-selection rules for `MinimalMainView`, kept apart from the view so
/// they stay pure and unit-tested.
extension MinimalMainView {
    /// Which action the appointment card offers. Extracted so the nil-vs-nil
    /// trap below stays covered by tests: an appointment with no session and no
    /// active recording are BOTH `nil`, and a bare `==` reads that as "this is
    /// the recording in flight" — showing Stop Recording on a session that was
    /// never started, whose button then no-ops.
    enum AppointmentAction: Equatable {
        case start
        case starting
        case stopRecording
    }

    static func action(
        for appointment: Appointment,
        activeSessionId: String?,
        startingAppointmentId: String? = nil
    ) -> AppointmentAction {
        if let sessionId = appointment.sessionId, sessionId == activeSessionId {
            return .stopRecording
        }
        return appointment.id == startingAppointmentId ? .starting : .start
    }

    /// The appointment the card shows.
    ///
    /// A session being recorded pins the card regardless of its end time or
    /// status. Without this, the moment the scheduled end passed the `end >= now`
    /// filter dropped the appointment, the window flipped to "all caught up",
    /// and a still-running recording lost its only End Session button. An
    /// appointment mid-start is pinned the same way: its `session_id` lands
    /// before `activeSessionId` is set, and the filter below would skip it.
    ///
    /// Otherwise an appointment that already has a session is done — ended
    /// here, possibly well before its scheduled end — so the card advances to
    /// the next one instead of parking on a session that can't be acted on.
    static func nextAppointment(
        in appointments: [Appointment],
        now: Date,
        activeSessionId: String? = nil,
        startingAppointmentId: String? = nil
    ) -> Appointment? {
        // The live recording outranks one mid-start: it holds the End Session button.
        let recording = activeSessionId.flatMap { id in appointments.first { $0.sessionId == id } }
        if let recording { return recording }
        let starting = appointments.first { $0.id == startingAppointmentId }
        if let starting { return starting }
        return appointments
            .compactMap { appointment -> (appointment: Appointment, start: Date)? in
                guard appointment.status.lowercased() != "cancelled",
                      appointment.sessionId == nil,
                      let start = parseDate(appointment.startAt),
                      let end = parseDate(appointment.endAt),
                      end >= now
                else {
                    return nil
                }
                return (appointment, start)
            }
            .min { $0.start < $1.start }?
            .appointment
    }

    /// An appointment whose session is being recorded somewhere other than this
    /// Mac — another device, or a recording this app lost track of.
    ///
    /// Shown as a note, never as the card: a session left open elsewhere must
    /// not stand between the therapist and the next Start Session. Only while
    /// the appointment's slot is still current, so a session someone forgot to
    /// end doesn't linger all day. Needs `session_status` from the backend;
    /// without it, nothing is reported.
    static func inProgressElsewhere(
        in appointments: [Appointment],
        now: Date,
        activeSessionId: String? = nil,
        startingAppointmentId: String? = nil
    ) -> Appointment? {
        appointments.first { appointment in
            guard appointment.sessionStatus == .inProgress,
                  let sessionId = appointment.sessionId,
                  sessionId != activeSessionId,
                  appointment.id != startingAppointmentId,
                  let end = parseDate(appointment.endAt)
            else { return false }
            return end >= now
        }
    }

    static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func timingLabel(_ appointment: Appointment, now: Date) -> String {
        guard let start = parseDate(appointment.startAt) else { return "UPCOMING" }
        if let end = parseDate(appointment.endAt), end < now { return "RUNNING OVER" }
        return start <= now ? "IN PROGRESS" : "NEXT UP"
    }
}
