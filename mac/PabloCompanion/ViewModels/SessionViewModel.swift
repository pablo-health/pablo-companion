import Foundation
import os

/// ViewModel for session management — powers the day view and session lifecycle.
///
/// Provides today's sessions, ad-hoc session creation, and session status transitions.
/// Wired to the Rust API client via APIClient (thin wrapper over UniFFI).
@MainActor
@Observable
final class SessionViewModel {
    // MARK: - Published state

    /// Today's scheduled sessions, refreshed by `loadTodaySessions()`.
    var todaySessions: [Session] = []

    /// Whether a data load is in progress.
    var isLoading = false

    /// User-facing error message (set on failure, cleared on next success).
    var errorMessage: String?
    var showError = false

    // MARK: - Dependencies

    /// Set by ContentView after discovering the backend URL.
    var backendURL = "http://localhost:8000" {
        didSet {
            if URLValidator.validateScheme(backendURL) == nil {
                apiClient = APIClient(baseURL: backendURL)
            }
        }
    }

    private var apiClient: APIClient
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "SessionViewModel")

    init() {
        self.apiClient = APIClient()
    }

    // MARK: - Auth

    /// Configures the API client with a token provider for authenticated requests.
    func configureAuth(getToken: @escaping @Sendable () async throws -> String) {
        apiClient.getToken = getToken
    }

    // MARK: - Today's sessions

    /// Fetches today's sessions from the backend.
    func loadTodaySessions() async {
        isLoading = true
        errorMessage = nil

        do {
            let timezone = TimeZone.current.identifier
            todaySessions = try await apiClient.fetchTodaySessions(timezone: timezone)
            logger.info("Loaded \(self.todaySessions.count) sessions for today")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to load today's sessions: \(error.localizedDescription)")
        }

        isLoading = false
    }

    // MARK: - Ad-hoc session creation

    /// Creates a new ad-hoc session for the given patient and starts it immediately.
    /// Used by the "Quick Start" flow.
    func createAdHocSession(patientId: String) async -> Session? {
        isLoading = true
        errorMessage = nil

        do {
            let request = CreateSessionRequest(
                patientId: patientId,
                scheduledAt: ISO8601DateFormatter().string(from: Date()),
                durationMinutes: 50,
                videoLink: nil,
                videoPlatform: nil,
                sessionType: nil,
                source: .companion,
                notes: nil
            )
            let session = try await apiClient.createSession(request: request)
            logger.info("Created ad-hoc session: \(session.id)")

            // Refresh today's list to include the new session
            await loadTodaySessions()

            isLoading = false
            return session
        } catch {
            errorMessage = error.localizedDescription
            showError = true
            logger.error("Failed to create ad-hoc session: \(error.localizedDescription)")
            isLoading = false
            return nil
        }
    }

    // MARK: - Session lifecycle

    /// Transitions a session to "in_progress" — called when the therapist clicks "Start Session".
    func startSession(_ sessionId: String) async -> Session? {
        do {
            let session = try await apiClient.updateSessionStatus(
                sessionId: sessionId,
                status: .inProgress
            )
            updateLocal(session)
            logger.info("Started session \(sessionId)")
            return session
        } catch {
            errorMessage = error.localizedDescription
            showError = true
            logger.error("Failed to start session \(sessionId): \(error.localizedDescription)")
            return nil
        }
    }

    /// Transitions a session to "recording_complete" — called when recording stops.
    func endSession(_ sessionId: String) async -> Session? {
        do {
            let session = try await apiClient.updateSessionStatus(
                sessionId: sessionId,
                status: .recordingComplete
            )
            updateLocal(session)
            logger.info("Ended session \(sessionId)")
            return session
        } catch {
            errorMessage = error.localizedDescription
            showError = true
            logger.error("Failed to end session \(sessionId): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Private helpers

    /// Updates the local todaySessions array with the latest server state.
    private func updateLocal(_ session: Session) {
        if let index = todaySessions.firstIndex(where: { $0.id == session.id }) {
            todaySessions[index] = session
        }
    }
}
