import Foundation
import Observation
import OSLog

/// Holds an incoming `pablohealth://` URL until ContentView is authenticated and able
/// to act on it. Cold-launch from the browser fires `.onOpenURL` before sign-in
/// finishes, so the router buffers the URL and ContentView drains it on auth state
/// change.
@Observable
final class DeepLinkRouter {
    var pendingURL: URL?

    static let logger = Logger(subsystem: "health.pablo.companion", category: "DeepLink")
}

/// Parsed action extracted from a `pablohealth://` URL. Only `startSession(appointment:)`
/// is wired up in v1.0; other resources are recognised so logging can flag them
/// as deferred rather than crashing.
enum DeepLinkAction {
    case startSessionFromAppointment(appointmentId: String)
    case unsupported(reason: String)

    init(url: URL) {
        guard url.scheme?.lowercased() == "pablohealth" else {
            self = .unsupported(reason: "non-pablohealth scheme: \(url.scheme ?? "nil")")
            return
        }
        let host = url.host?.lowercased() ?? ""
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []

        if host == "session", path == "start" {
            if let id = query.first(where: { $0.name == "appointment" })?.value, !id.isEmpty {
                self = .startSessionFromAppointment(appointmentId: id)
                return
            }
            self = .unsupported(reason: "session/start without appointment param (deferred: patient=)")
            return
        }
        self = .unsupported(reason: "deferred resource: \(host)/\(path)")
    }
}
