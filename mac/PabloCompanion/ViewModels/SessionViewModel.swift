import Foundation
import os
import PracticeClientCore

/// ViewModel for session management — powers the day view, session history, and session lifecycle.
///
/// Provides today's sessions, paginated session history, ad-hoc session creation,
/// and session status transitions.
/// Wired to the Rust API client via APIClient (thin wrapper over UniFFI).
@MainActor
@Observable
final class SessionViewModel {
    // MARK: - Published state (today — appointments)

    /// Today's calendar appointments, refreshed by `loadTodayAppointments()`.
    var todayAppointments: [Appointment] = []

    /// Today's scheduled sessions (legacy, used by session history).
    var todaySessions: [Session] = []

    /// Whether a data load is in progress.
    var isLoading = false

    /// User-facing error message (set on failure, cleared on next success).
    var errorMessage: String?
    var showError = false

    /// Set when a 403 indicates the subscription has lapsed.
    /// ContentView observes this to trigger a subscription status refresh.
    var subscriptionBlocked = false

    // MARK: - Published state (session history)

    /// All sessions (paginated), refreshed by `loadSessions()`.
    var sessions: [Session] = []

    /// Total number of sessions matching the current filter.
    var totalSessions: UInt32 = 0

    /// Current page for paginated session fetching.
    var currentPage = 1

    /// Whether more sessions are available beyond the current page.
    var hasMoreSessions = false

    /// Optional status filter for session history (nil = all statuses).
    var statusFilter: String? {
        didSet { Task { await loadSessions() } }
    }

    /// Whether a session history load is in progress (separate from today's loading).
    var isLoadingSessions = false

    // MARK: - Dependencies

    /// Set by ContentView after discovering the backend URL.
    var backendURL = "https://api.pablo.health" {
        didSet {
            if URLValidator.validateScheme(backendURL) == nil {
                let token = apiClient.getToken
                let onAuthRejected = apiClient.onAuthRejected
                apiClient = APIClient(baseURL: backendURL)
                apiClient.getToken = token
                apiClient.onAuthRejected = onAuthRejected
            }
        }
    }

    private var apiClient: APIClient
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "SessionViewModel")

    init() {
        self.apiClient = APIClient()
    }

    // MARK: - Auth

    /// Configures the API client with a token provider for authenticated
    /// requests, and optionally a handler fired when the server rejects the
    /// session (401) so the UI can bounce to re-auth.
    func configureAuth(
        getToken: @escaping @Sendable () async throws -> String,
        onAuthRejected: ((Bool) -> Void)? = nil
    ) {
        apiClient.getToken = getToken
        apiClient.onAuthRejected = onAuthRejected
    }

    // MARK: - Session keep-alive

    /// How often to refresh the server-side idle heartbeat while recording.
    /// The server window is 15 minutes; 4 minutes keeps a comfortable margin
    /// even if one touch is lost to a network blip.
    static let keepAliveInterval: Duration = .seconds(240)

    /// Keeps the backend idle session alive for the duration of a recording.
    ///
    /// During a recording the app makes no other backend calls (capture is
    /// local; upload happens at stop), so without a deliberate heartbeat the
    /// server-side idle timeout can tombstone the session right before the
    /// stop-time upload. An active recording is genuine user activity — the
    /// local inactivity lock is already suspended while recording — so the
    /// server session should stay alive too.
    ///
    /// Runs until cancelled (the caller scopes it to the active recording).
    /// Starts with a read-only liveness probe so a session that is already
    /// dead surfaces the re-auth flow immediately; each subsequent touch that
    /// hits a 401 does the same via the client's `onAuthRejected` hook. Other
    /// failures are ignored — the next tick retries, and a lost heartbeat
    /// must never interfere with the recording itself.
    func keepSessionAliveWhileRecording() async {
        guard await apiClient.verifySessionAlive() else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.keepAliveInterval)
            guard !Task.isCancelled else { break }
            do {
                _ = try await apiClient.touchSession()
            } catch {
                logger.warning("Session keep-alive touch failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Today's appointments

    /// Fetches today's calendar appointments from the backend.
    func loadTodayAppointments() async {
        let isFirstLoad = todayAppointments.isEmpty
        if isFirstLoad { isLoading = true }
        errorMessage = nil

        do {
            todayAppointments = try await apiClient.fetchTodayAppointments()
            logger.info("Loaded \(self.todayAppointments.count) today appointments")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to load today's appointments: \(error)")
        }

        isLoading = false
    }

    /// Creates a therapy session from a calendar appointment.
    /// Returns the created session, or nil on failure.
    func startSessionFromAppointment(appointmentId: String) async -> Session? {
        errorMessage = nil

        do {
            let session = try await apiClient.startSessionFromAppointment(appointmentId: appointmentId)
            logger.info("Created session from appointment")
            // Refresh appointments to pick up the linked session_id
            await loadTodayAppointments()
            return session
        } catch {
            if case let APIError.serverError(statusCode, _) = error, statusCode == 403 {
                subscriptionBlocked = true
            }
            errorMessage = error.localizedDescription
            showError = true
            logger.error("Failed to start session from appointment: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Today's sessions (legacy)

    /// Fetches today's sessions from the backend.
    func loadTodaySessions() async {
        let isFirstLoad = todaySessions.isEmpty
        if isFirstLoad { isLoading = true }
        errorMessage = nil

        do {
            let timezone = TimeZone.current.identifier
            todaySessions = try await apiClient.fetchTodaySessions(timezone: timezone)
            logger.info("Loaded \(self.todaySessions.count) today sessions")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to load today's sessions: \(error)")
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
                sessionType: .individual,
                source: .companion,
                notes: nil
            )
            let session = try await apiClient.createSession(request: request)
            logger.info("Created ad-hoc session")

            // Refresh today's list — safe because recording hasn't started yet.
            await loadTodaySessions()

            isLoading = false
            return session
        } catch {
            if case let APIError.serverError(statusCode, _) = error, statusCode == 403 {
                subscriptionBlocked = true
            }
            errorMessage = error.localizedDescription
            showError = true
            logger.error("Failed to create ad-hoc session: \(error.localizedDescription)")
            isLoading = false
            return nil
        }
    }

    // MARK: - Launch intent

    /// Outcome of redeeming a web-issued launch intent.
    enum LaunchRedeemResult: Equatable {
        /// Intent redeemed — confirm with the therapist before arming the mic.
        case confirm(LaunchContext)
        /// Intent no longer valid (already redeemed, expired, or unknown — `410`).
        case expired
        /// Any other failure (network, auth). Carries a non-PHI message.
        case failed(message: String)
    }

    /// The non-secret context needed to render the "Start session with X?"
    /// confirmation. Deliberately small — `patientName` is the only PHI and it
    /// never leaves this struct's render path.
    struct LaunchContext: Equatable {
        let appointmentId: String
        let patientName: String?
    }

    /// Redeems a launch intent against the backend checkpoint. Never throws —
    /// maps every outcome onto `LaunchRedeemResult` so the UI can present a
    /// consistent confirmation / expired / error state without leaking PHI.
    func redeemLaunchIntent(intentId: String) async -> LaunchRedeemResult {
        do {
            let redemption = try await apiClient.redeemLaunchIntent(intentId: intentId)
            logger.info("Launch intent redeemed; awaiting confirmation")
            return .confirm(
                LaunchContext(
                    appointmentId: redemption.appointmentId,
                    patientName: redemption.patientName
                )
            )
        } catch let PabloError.apiClient(statusCode, _, _) where statusCode == 410 {
            logger.info("Launch intent no longer valid (410)")
            return .expired
        } catch {
            logger.error("Launch intent redemption failed: \(error.localizedDescription)")
            return .failed(message: "Couldn't open this session. Please start again from the dashboard.")
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
            logger.info("Started session")
            return session
        } catch {
            if case let APIError.serverError(statusCode, _) = error, statusCode == 403 {
                subscriptionBlocked = true
            }
            errorMessage = error.localizedDescription
            showError = true
            logger.error("Failed to start session: \(error.localizedDescription)")
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
            logger.info("Ended session")
            return session
        } catch {
            errorMessage = error.localizedDescription
            showError = true
            logger.error("Failed to end session: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Session history

    /// Fetches the first page of sessions from the backend, replacing the current list.
    func loadSessions() async {
        isLoadingSessions = true
        currentPage = 1
        errorMessage = nil

        do {
            let response = try await apiClient.fetchSessions(
                page: currentPage,
                pageSize: 20,
                status: statusFilter
            )
            sessions = response.data.filter { matchesFilter($0) }
            totalSessions = response.total
            hasMoreSessions = response.hasMore
            logger.info("Loaded sessions page")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to load sessions: \(error.localizedDescription)")
        }

        isLoadingSessions = false
    }

    /// Fetches the next page of sessions and appends them to the current list.
    func loadMoreSessions() async {
        guard hasMoreSessions, !isLoadingSessions else { return }
        isLoadingSessions = true
        currentPage += 1

        do {
            let response = try await apiClient.fetchSessions(
                page: currentPage,
                pageSize: 20,
                status: statusFilter
            )
            sessions.append(contentsOf: response.data.filter { matchesFilter($0) })
            totalSessions = response.total
            hasMoreSessions = response.hasMore
            logger.info("Loaded next sessions page")
        } catch {
            currentPage -= 1
            errorMessage = error.localizedDescription
            logger.error("Failed to load more sessions: \(error.localizedDescription)")
        }

        isLoadingSessions = false
    }

    /// Client-side filter — ensures correct filtering even if the backend ignores the `status` param.
    private func matchesFilter(_ session: Session) -> Bool {
        guard let filter = statusFilter else { return true }
        switch filter {
        case "scheduled": return session.status == .scheduled
        case "in_progress": return session.status == .inProgress
        case "recording_complete": return session.status == .recordingComplete
        case "finalized": return session.status == .finalized
        case "cancelled": return session.status == .cancelled
        default: return true
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
