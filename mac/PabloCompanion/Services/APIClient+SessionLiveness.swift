import Foundation
import PracticeClientCore

// MARK: - Session Liveness

/// Server-side idle-session endpoints: read-only peek and explicit keep-alive.
/// The backend tombstones a session after 15 minutes without an authenticated
/// request; these let the companion detect a dead session before an upload and
/// keep the session alive during a recording (when no other calls happen).
extension APIClient {
    /// Read-only peek at the server-side idle session. Does NOT extend the
    /// session — checking liveness must not keep it alive.
    func fetchSessionStatus() async throws -> SessionLiveness {
        let request = try await buildRequest("GET", path: "/api/auth/session")
        let (data, response) = try await URLSession.shared.data(for: request)
        try mapHTTPErrors(data: data, response: response)

        return try handleResponse(data, response)
    }

    /// Explicit keep-alive: refreshes the server-side idle heartbeat. Used
    /// while a recording is active, when the app makes no other backend calls
    /// and would otherwise idle out mid-session.
    func touchSession() async throws -> SessionLiveness {
        let request = try await buildRequest("POST", path: "/api/auth/session/touch")
        let (data, response) = try await URLSession.shared.data(for: request)
        try mapHTTPErrors(data: data, response: response)

        return try handleResponse(data, response)
    }

    /// Probes session liveness and reports whether it is safe to proceed with
    /// an authenticated call. Returns `false` only when the server positively
    /// says the session is dead (dead peek, or a 401 on the probe itself —
    /// `onAuthRejected` has already fired in both cases). Network or decoding
    /// failures return `true`: the probe is advisory and must never block
    /// work that has its own retry path.
    func verifySessionAlive() async -> Bool {
        do {
            let status = try await fetchSessionStatus()
            if status.enforced, !status.active {
                onAuthRejected?(true)
                return false
            }
            return true
        } catch PabloError.unauthenticated {
            return false
        } catch {
            return true
        }
    }
}
