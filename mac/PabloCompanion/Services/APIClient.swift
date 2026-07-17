import Foundation
import os
import PracticeClientCore

/// Native URLSession-based API client for the Pablo backend.
/// Replaces the previous Rust FFI (pablo-core) delegation with direct HTTP calls.
@MainActor
final class APIClient {
    let logger = Logger(subsystem: AppConstants.appBundleID, category: "APIClient")

    nonisolated let baseURL: URL
    nonisolated let baseURLString: String

    /// Optional closure to provide a Bearer token for authenticated requests.
    var getToken: (@Sendable () async throws -> String)?

    /// Fired when an authenticated request comes back 401. Mirrors the Windows
    /// `UnauthenticatedDetected` event: the auth layer listens and drives the UI
    /// back to sign-in instead of leaving callers to retry a session the server
    /// has already rejected. A Firebase token refresh cannot recover here — the
    /// backend's idle timeout is keyed on `auth_time`, which a refresh preserves —
    /// so only a fresh interactive sign-in helps. `idleTimeout` is true when the
    /// body's structured `error.code` is `IDLE_TIMEOUT`, so the UI can say
    /// "expired due to inactivity" rather than a generic auth failure.
    var onAuthRejected: ((_ idleTimeout: Bool) -> Void)?

    /// Structured error code the backend attaches to idle-timeout 401s.
    static let idleTimeoutCode = "IDLE_TIMEOUT"

    /// The shipping app version, read from the bundle rather than hardcoded.
    ///
    /// A literal here silently stayed at `0.9.1` across the 1.0.0 release. Since
    /// `healthCheck` compares this against `min_client_versions.macos`, the day
    /// the backend required 1.0.0 every up-to-date client would have reported
    /// `clientUpdateRequired` and demanded an update it already had. Sourcing it
    /// from `MARKETING_VERSION` makes that drift impossible.
    static let clientVersion: String =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

    private static let minServerVersion = "0.9.0"

    private static let fallbackURL: URL = {
        // Static string — guaranteed to parse. Extracted to avoid force-unwrap at call site.
        guard let url = URL(string: "https://api.pablo.health") else {
            preconditionFailure("Hardcoded fallback URL is invalid")
        }
        return url
    }()

    nonisolated private let jsonDecoder = JSONDecoder()
    nonisolated private let jsonEncoder = JSONEncoder()

    init(baseURL: String = "https://api.pablo.health") {
        guard URLValidator.validateScheme(baseURL) == nil,
              let url = URL(string: baseURL)
        else {
            // Placeholder URL — will be overwritten by configureAndLoad() after auth.
            // Non-fatal so the app can still launch and reach the login screen.
            self.baseURL = Self.fallbackURL
            self.baseURLString = Self.fallbackURL.absoluteString
            return
        }
        self.baseURL = url
        self.baseURLString = baseURL
    }

    // MARK: - Token helper

    func requireToken() async throws -> String {
        guard let getToken else {
            throw APIError.notAuthenticated
        }
        return try await getToken()
    }

    // MARK: - Health

    /// Checks backend reachability and version compatibility.
    /// This endpoint does NOT require authentication.
    func healthCheck() async throws -> HealthStatus {
        let request = try await buildRequest("GET", path: "/api/health", authenticated: false)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw PabloError.apiClient(statusCode: UInt16(httpResponse.statusCode), message: message)
        }

        // Parse the raw JSON to extract version fields manually,
        // matching the Rust implementation's behavior.
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PabloError.jsonParse(message: "Health response is not a JSON object")
        }

        let serverVersion = json["server_version"] as? String ?? "unknown"

        // Extract minimum client version for macOS from nested object
        var minClientVersion = "0.0.0"
        if let minClientVersions = json["min_client_versions"] as? [String: Any] {
            if let macosMin = minClientVersions["macos"] as? String {
                minClientVersion = macosMin
            }
        }

        // Compare versions to determine compatibility
        let clientUpdateRequired = Self.isVersion(Self.clientVersion, lessThan: minClientVersion)
        let serverUpdateRequired = Self.isVersion(serverVersion, lessThan: Self.minServerVersion)

        return HealthStatus(
            serverVersion: serverVersion,
            clientUpdateRequired: clientUpdateRequired,
            serverUpdateRequired: serverUpdateRequired,
            minClientVersion: minClientVersion,
            minServerVersion: Self.minServerVersion
        )
    }

    // MARK: - Patients

    /// Fetches a paginated list of patients.
    func fetchPatients(
        search: String = "",
        page: Int = 1,
        pageSize: Int = 50
    ) async throws -> PatientListResponse {
        var path = "/api/patients?page=\(page)&page_size=\(pageSize)"
        if !search.isEmpty, let encoded = search.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&search=\(encoded)"
        }

        let request = try await buildRequest("GET", path: path)
        let (data, response) = try await URLSession.shared.data(for: request)
        try mapHTTPErrors(data: data, response: response)

        let decoded: PatientListResponse = try handleResponse(data, response)
        logger.info("Fetched patients page")
        return decoded
    }

    /// Creates a new patient.
    func createPatient(
        firstName: String,
        lastName: String,
        email: String? = nil,
        phone: String? = nil,
        dateOfBirth: String? = nil,
        diagnosis: String? = nil
    ) async throws -> Patient {
        let body = CreatePatientRequest(
            firstName: firstName,
            lastName: lastName,
            email: email,
            phone: phone,
            dateOfBirth: dateOfBirth,
            diagnosis: diagnosis
        )

        var request = try await buildRequest("POST", path: "/api/patients")
        request.httpBody = try jsonEncoder.encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try mapHTTPErrors(data: data, response: response)

        let patient: Patient = try handleResponse(data, response)
        logger.info("Created patient")
        return patient
    }

    // MARK: - Appointments

    /// Fetches today's appointments for the day view.
    func fetchTodayAppointments() async throws -> [Appointment] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else {
            return []
        }
        let fmt = ISO8601DateFormatter()
        let startStr = fmt.string(from: start)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let endStr = fmt.string(from: end)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let path = "/api/appointments?start=\(startStr)&end=\(endStr)"

        let request = try await buildRequest("GET", path: path)
        let (data, response) = try await URLSession.shared.data(for: request)
        try mapHTTPErrors(data: data, response: response)

        let listResponse: AppointmentListResponse = try handleResponse(data, response)
        logger.info("Fetched today's appointments: \(listResponse.data.count)")
        return listResponse.data
    }

    /// Creates a therapy session linked to a calendar appointment.
    func startSessionFromAppointment(appointmentId: String) async throws -> Session {
        let request = try await buildRequest(
            "POST",
            path: "/api/appointments/\(appointmentId)/start-session"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        try mapHTTPErrors(data: data, response: response)

        let session: Session = try handleResponse(data, response)
        logger.info("Started session from appointment")
        return session
    }

    // MARK: - Launch intent

    /// Redeems a launch intent issued by the web dashboard. The companion
    /// presents its existing bearer token; the backend verifies the intent is
    /// unconsumed, unexpired, and bound to this user, marks it consumed, and
    /// returns the appointment context to confirm with the therapist.
    ///
    /// A `410 Gone` (surfaced as `PabloError.apiClient(statusCode: 410, ...)` —
    /// 410 has no dedicated case in `mapHTTPErrors`, so it falls to the default)
    /// means the intent is no longer valid — already redeemed via the other
    /// handoff path, expired, or unknown. Callers should treat that as a benign
    /// "already handled / link expired", not a hard error.
    func redeemLaunchIntent(intentId: String) async throws -> LaunchRedemption {
        var request = try await buildRequest("POST", path: "/api/launch/redeem")
        let body = ["intent_id": intentId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try mapHTTPErrors(data: data, response: response)

        let decoded: LaunchRedemption = try handleResponse(data, response)
        logger.info("Redeemed launch intent")
        return decoded
    }

    // MARK: - Sessions

    /// Fetches today's sessions for the given timezone.
    func fetchTodaySessions(timezone: String) async throws -> [Session] {
        let encodedTZ = timezone.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? timezone
        let path = "/api/sessions/today?timezone=\(encodedTZ)"

        let request = try await buildRequest("GET", path: path)
        let (data, response) = try await URLSession.shared.data(for: request)
        try mapHTTPErrors(data: data, response: response)

        let listResponse: TodaySessionListResponse = try handleResponse(data, response)
        logger.info("Fetched today's sessions")
        return listResponse.data
    }

    /// Creates a new therapy session.
    func createSession(request: CreateSessionRequest) async throws -> Session {
        var urlRequest = try await buildRequest("POST", path: "/api/sessions/schedule")
        urlRequest.httpBody = try jsonEncoder.encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try mapHTTPErrors(data: data, response: response)

        let session: Session = try handleResponse(data, response)
        logger.info("Created session")
        return session
    }

    /// Fetches a single session by ID.
    func fetchSession(sessionId: String) async throws -> Session {
        let request = try await buildRequest("GET", path: "/api/sessions/\(sessionId)")
        let (data, response) = try await URLSession.shared.data(for: request)
        try mapHTTPErrors(data: data, response: response)

        return try handleResponse(data, response)
    }

    /// Fetches a paginated list of sessions.
    func fetchSessions(
        page: Int = 1,
        pageSize: Int = 50,
        status: String? = nil
    ) async throws -> SessionListResponse {
        var path = "/api/sessions?page=\(page)&page_size=\(pageSize)"
        if let status {
            path += "&status=\(status)"
        }

        let request = try await buildRequest("GET", path: path)
        let (data, response) = try await URLSession.shared.data(for: request)
        try mapHTTPErrors(data: data, response: response)

        let decoded: SessionListResponse = try handleResponse(data, response)
        logger.info("Fetched sessions page")
        return decoded
    }

    /// Updates a session's status.
    func updateSessionStatus(
        sessionId: String,
        status: SessionStatus
    ) async throws -> Session {
        var request = try await buildRequest("PATCH", path: "/api/sessions/\(sessionId)/status")
        let body = ["status": status.rawValue]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try mapHTTPErrors(data: data, response: response)

        let session: Session = try handleResponse(data, response)
        logger.info("Updated session status")
        return session
    }

    /// Updates a session's fields.
    func updateSession(
        sessionId: String,
        request: UpdateSessionRequest
    ) async throws -> Session {
        var urlRequest = try await buildRequest("PATCH", path: "/api/sessions/\(sessionId)")
        urlRequest.httpBody = try jsonEncoder.encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try mapHTTPErrors(data: data, response: response)

        let session: Session = try handleResponse(data, response)
        logger.info("Updated session")
        return session
    }

    /// Finalizes a session with a quality rating.
    func finalizeSession(
        sessionId: String,
        qualityRating: UInt8
    ) async throws -> Session {
        var request = try await buildRequest("PATCH", path: "/api/sessions/\(sessionId)/finalize")
        let body: [String: Any] = ["quality_rating": Int(qualityRating)]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try mapHTTPErrors(data: data, response: response)

        let session: Session = try handleResponse(data, response)
        logger.info("Finalized session")
        return session
    }

    // MARK: - Transcripts

    /// Uploads a transcript for a session.
    func uploadTranscript(
        sessionId: String,
        format: String,
        content: String
    ) async throws -> TranscriptUploadResponse {
        var request = try await buildRequest("POST", path: "/api/sessions/\(sessionId)/transcript")
        let body: [String: String] = ["format": format, "content": content]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try mapHTTPErrors(data: data, response: response)

        let decoded: TranscriptUploadResponse = try handleResponse(data, response)
        logger.info("Uploaded transcript")
        return decoded
    }

    // MARK: - User Profile

    /// Fetches the authenticated user's profile.
    func fetchUserProfile() async throws -> UserProfile {
        let request = try await buildRequest("GET", path: "/api/users/me")
        let (data, response) = try await URLSession.shared.data(for: request)
        try mapHTTPErrors(data: data, response: response)

        return try handleResponse(data, response)
    }

    // MARK: - BAA

    /// Fetches the BAA acceptance status.
    func fetchBaaStatus() async throws -> BaaStatus {
        let request = try await buildRequest("GET", path: "/api/users/me/baa-status")
        let (data, response) = try await URLSession.shared.data(for: request)
        try mapHTTPErrors(data: data, response: response)

        return try handleResponse(data, response)
    }

    /// Accepts the BAA.
    func acceptBaa() async throws -> BaaStatus {
        let request = try await buildRequest("POST", path: "/api/users/me/accept-baa")
        let (data, response) = try await URLSession.shared.data(for: request)
        try mapHTTPErrors(data: data, response: response)

        let status: BaaStatus = try handleResponse(data, response)
        logger.info("BAA accepted")
        return status
    }

    // MARK: - Preferences

    /// Fetches user preferences.
    func fetchPreferences() async throws -> UserPreferences {
        let request = try await buildRequest("GET", path: "/api/users/me/preferences")
        let (data, response) = try await URLSession.shared.data(for: request)
        try mapHTTPErrors(data: data, response: response)

        return try handleResponse(data, response)
    }

    /// Saves user preferences.
    func savePreferences(_ preferences: UserPreferences) async throws -> UserPreferences {
        var request = try await buildRequest("PUT", path: "/api/users/me/preferences")
        request.httpBody = try jsonEncoder.encode(preferences)

        let (data, response) = try await URLSession.shared.data(for: request)
        try mapHTTPErrors(data: data, response: response)

        let prefs: UserPreferences = try handleResponse(data, response)
        logger.info("Preferences saved")
        return prefs
    }

    // MARK: - Private Helpers

    /// Builds a URLRequest with standard headers. Internal (not private) so
    /// same-type extensions in other files can build requests the standard
    /// way instead of hand-rolling them.
    /// - Parameters:
    ///   - method: HTTP method (GET, POST, PATCH, PUT, DELETE).
    ///   - path: API path (e.g. "/api/sessions"). Appended to `baseURLString`.
    ///   - authenticated: Whether to include the Authorization header. Defaults to `true`.
    /// - Returns: A configured URLRequest.
    func buildRequest(
        _ method: String,
        path: String,
        authenticated: Bool = true
    ) async throws -> URLRequest {
        guard let url = URL(string: "\(baseURLString)\(path)") else {
            throw APIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method

        // Standard client identification headers
        request.setValue("pablo-companion-macos/1.0", forHTTPHeaderField: "X-Client-Type")
        request.setValue(Self.clientVersion, forHTTPHeaderField: "X-Client-Version")
        request.setValue("macos", forHTTPHeaderField: "X-Client-Platform")

        // Content-Type for mutating requests
        if method == "POST" || method == "PATCH" || method == "PUT" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        // Auth header
        if authenticated {
            let token = try await requireToken()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            // Device binding (DPoP proof + X-Install-ID) for enrolled installs.
            // Centralized here so every authenticated path built through
            // buildRequest carries the proof — no call site can forget it.
            Self.attachDeviceBinding(to: &request)
        }

        return request
    }

    /// Decodes a successful HTTP response body into the requested type.
    /// Internal (not private) for the same extension-file reason as `buildRequest`.
    func handleResponse<T: Decodable>(_ data: Data, _: URLResponse) throws -> T {
        do {
            return try jsonDecoder.decode(T.self, from: data)
        } catch let DecodingError.keyNotFound(key, context) {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw PabloError.jsonParse(
                message: "Missing key '\(key.stringValue)' at \(path.isEmpty ? "root" : path)"
            )
        } catch let DecodingError.typeMismatch(type, context) {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw PabloError.jsonParse(
                message: "Type mismatch for \(type) at \(path.isEmpty ? "root" : path)"
            )
        } catch {
            throw PabloError.jsonParse(message: "\(error.localizedDescription)")
        }
    }

}
