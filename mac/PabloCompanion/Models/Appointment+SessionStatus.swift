extension Appointment {
    /// Lifecycle of the linked session. `session_status` is decoded raw so a
    /// status a newer backend adds reads as `nil` here instead of failing the
    /// whole appointment list; older backends omit it entirely.
    var sessionStatus: SessionStatus? {
        sessionStatusRaw.flatMap(SessionStatus.init(rawValue:))
    }
}
