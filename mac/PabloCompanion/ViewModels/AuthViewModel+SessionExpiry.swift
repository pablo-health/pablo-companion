import Foundation
import os

// MARK: - Server Session Rejection

/// Handles the backend rejecting the session (401) out from under a signed-in
/// app — most commonly the server-side idle timeout, which tombstones a
/// session after 15 minutes without an authenticated request.
extension AuthViewModel {
    private static let logger = Logger(
        subsystem: AppConstants.appBundleID, category: "AuthViewModel"
    )

    /// Handles a 401 from an authenticated API call: signs out and surfaces a
    /// re-auth prompt. Mirrors Windows `OnApiUnauthenticated`. Refreshing the
    /// Firebase token would not help — the backend enforces a server-side idle
    /// timeout keyed on `auth_time`, and a refresh re-issues a token with the
    /// same `auth_time` — so we go straight to sign-in. Pending upload queues
    /// live on disk and survive the sign-out; they drain after re-auth.
    func handleAuthRejected(idleTimeout: Bool) {
        guard !isHandlingAuthRejection else { return }
        guard case .authenticated = authState else { return }
        isHandlingAuthRejection = true
        defer { isHandlingAuthRejection = false }

        Self.logger.info("Server rejected session (idleTimeout: \(idleTimeout)) — signing out")
        signOut()
        errorMessage = Self.sessionRejectedMessage(idleTimeout: idleTimeout)
    }

    /// User-facing message for a server-side session rejection. Idle timeouts
    /// get a distinct message so the therapist knows why they were signed out.
    static func sessionRejectedMessage(idleTimeout: Bool) -> String {
        idleTimeout
            ? "Your session expired due to inactivity. Please sign in again."
            : "Your session is no longer valid. Please sign in again."
    }
}
