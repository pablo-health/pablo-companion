import Foundation
import os

/// Thin wrapper around pablo-core Rust API client.
/// Centralizes base URL and auth token so ViewModels don't scatter them.
@MainActor
final class APIClient {
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "APIClient")

    nonisolated let baseURL: URL
    nonisolated private let baseURLString: String

    /// Optional closure to provide a Bearer token for authenticated requests.
    var getToken: (@Sendable () async throws -> String)?

    private static let fallbackURL: URL = {
        // Static string — guaranteed to parse. Extracted to avoid force-unwrap at call site.
        guard let url = URL(string: "https://api.pablo.health") else {
            preconditionFailure("Hardcoded fallback URL is invalid")
        }
        return url
    }()

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

    private func requireToken() async throws -> String {
        guard let getToken else {
            throw APIError.notAuthenticated
        }
        return try await getToken()
    }

    // MARK: - Health

    /// Checks backend reachability and version compatibility via the Rust API client.
    func healthCheck() async throws -> HealthStatus {
        try await Pablo.healthCheck(baseUrl: baseURLString)
    }

    // MARK: - Recordings

    /// Uploads a recording file to the backend via the Rust API client.
    func uploadRecording(
        fileURL: URL,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> UploadResponse {
        let token = try await requireToken()
        logger.info("Uploading recording file")

        // Simulate incremental progress since the Rust client
        // doesn't provide upload progress callbacks.
        onProgress(0.3)

        let response = try await Pablo.uploadRecording(
            baseUrl: baseURLString,
            token: token,
            filePath: fileURL.path
        )

        onProgress(1.0)
        logger.info("Upload successful")
        return response
    }

    // MARK: - Patients

    /// Fetches a paginated list of patients via the Rust API client.
    func fetchPatients(
        search: String = "",
        page: Int = 1,
        pageSize: Int = 50
    ) async throws -> PatientListResponse {
        let token = try await requireToken()

        let response = try await Pablo.fetchPatients(
            baseUrl: baseURLString,
            token: token,
            search: search.isEmpty ? nil : search,
            page: UInt32(page),
            pageSize: UInt32(pageSize)
        )

        logger.info("Fetched patients page")
        return response
    }

    /// Creates a new patient via the Rust API client.
    func createPatient(
        firstName: String,
        lastName: String,
        email: String? = nil,
        phone: String? = nil,
        dateOfBirth: String? = nil,
        diagnosis: String? = nil
    ) async throws -> Patient {
        let token = try await requireToken()

        let request = CreatePatientRequest(
            firstName: firstName,
            lastName: lastName,
            email: email,
            phone: phone,
            dateOfBirth: dateOfBirth,
            diagnosis: diagnosis
        )

        let patient = try await Pablo.createPatient(
            baseUrl: baseURLString,
            token: token,
            request: request
        )

        logger.info("Created patient")
        return patient
    }

    // MARK: - Sessions

    /// Fetches today's sessions for the given timezone via the Rust API client.
    func fetchTodaySessions(timezone: String) async throws -> [Session] {
        let token = try await requireToken()

        let sessions = try await Pablo.fetchTodaySessions(
            baseUrl: baseURLString,
            token: token,
            timezone: timezone
        )

        logger.info("Fetched today's sessions")
        return sessions
    }

    /// Creates a new therapy session via the Rust API client.
    func createSession(request: CreateSessionRequest) async throws -> Session {
        let token = try await requireToken()

        let session = try await Pablo.createSession(
            baseUrl: baseURLString,
            token: token,
            request: request
        )

        logger.info("Created session")
        return session
    }

    /// Fetches a single session by ID via the Rust API client.
    func fetchSession(sessionId: String) async throws -> Session {
        let token = try await requireToken()

        return try await Pablo.fetchSession(
            baseUrl: baseURLString,
            token: token,
            sessionId: sessionId
        )
    }

    /// Fetches a paginated list of sessions via the Rust API client.
    func fetchSessions(
        page: Int = 1,
        pageSize: Int = 50,
        status: String? = nil
    ) async throws -> SessionListResponse {
        let token = try await requireToken()

        let response = try await Pablo.fetchSessions(
            baseUrl: baseURLString,
            token: token,
            page: UInt32(page),
            pageSize: UInt32(pageSize),
            status: status
        )

        logger.info("Fetched sessions page")
        return response
    }

    /// Updates a session's status via the Rust API client.
    func updateSessionStatus(
        sessionId: String,
        status: SessionStatus
    ) async throws -> Session {
        let token = try await requireToken()

        let session = try await Pablo.updateSessionStatus(
            baseUrl: baseURLString,
            token: token,
            sessionId: sessionId,
            status: status
        )

        logger.info("Updated session status")
        return session
    }

    /// Updates a session's fields via the Rust API client.
    func updateSession(
        sessionId: String,
        request: UpdateSessionRequest
    ) async throws -> Session {
        let token = try await requireToken()

        let session = try await Pablo.updateSession(
            baseUrl: baseURLString,
            token: token,
            sessionId: sessionId,
            request: request
        )

        logger.info("Updated session")
        return session
    }

    /// Finalizes a session with a quality rating via the Rust API client.
    func finalizeSession(
        sessionId: String,
        qualityRating: UInt8
    ) async throws -> Session {
        let token = try await requireToken()

        let session = try await Pablo.finalizeSession(
            baseUrl: baseURLString,
            token: token,
            sessionId: sessionId,
            qualityRating: qualityRating
        )

        logger.info("Finalized session")
        return session
    }

    // MARK: - Transcripts

    /// Uploads a transcript for a session via the Rust API client.
    func uploadTranscript(
        sessionId: String,
        format: String,
        content: String
    ) async throws -> TranscriptUploadResponse {
        let token = try await requireToken()

        let response = try await Pablo.uploadTranscript(
            baseUrl: baseURLString,
            token: token,
            sessionId: sessionId,
            format: format,
            content: content
        )

        logger.info("Uploaded transcript")
        return response
    }

    // MARK: - User Profile

    /// Fetches the authenticated user's profile via the Rust API client.
    func fetchUserProfile() async throws -> UserProfile {
        let token = try await requireToken()

        return try await Pablo.fetchUserProfile(
            baseUrl: baseURLString,
            token: token
        )
    }

    // MARK: - BAA

    /// Fetches the BAA acceptance status via the Rust API client.
    func fetchBaaStatus() async throws -> BaaStatus {
        let token = try await requireToken()

        return try await Pablo.fetchBaaStatus(
            baseUrl: baseURLString,
            token: token
        )
    }

    /// Accepts the BAA via the Rust API client.
    func acceptBaa() async throws -> BaaStatus {
        let token = try await requireToken()

        let status = try await Pablo.acceptBaa(
            baseUrl: baseURLString,
            token: token
        )

        logger.info("BAA accepted")
        return status
    }

    // MARK: - Preferences

    /// Fetches user preferences via the Rust API client.
    func fetchPreferences() async throws -> UserPreferences {
        let token = try await requireToken()

        return try await Pablo.fetchPreferences(
            baseUrl: baseURLString,
            token: token
        )
    }

    /// Saves user preferences via the Rust API client.
    func savePreferences(_ preferences: UserPreferences) async throws -> UserPreferences {
        let token = try await requireToken()

        let prefs = try await Pablo.savePreferences(
            baseUrl: baseURLString,
            token: token,
            preferences: preferences
        )

        logger.info("Preferences saved")
        return prefs
    }

    // MARK: - Multipart helper (kept for backward compat + tests)

    func createMultipartBody(
        fileData: Data,
        fileName: String,
        boundary: String
    ) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}

enum APIError: LocalizedError {
    case invalidResponse
    case serverError(statusCode: Int, message: String)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Invalid response from server."
        case let .serverError(code, message):
            "Server error (\(code)): \(message)"
        case .notAuthenticated:
            "Not authenticated. Please sign in."
        }
    }
}

/// Server configuration returned by the therapy-assistant-platform's /api/config endpoint.
struct ServerConfig: Codable, Sendable {
    let apiUrl: String
    let firebaseApiKey: String?
    let firebaseProjectId: String?
}

/// Fetches runtime configuration from the therapy-assistant-platform.
/// This discovers the backend API URL so the user doesn't have to enter it manually.
func fetchServerConfig(authServerURL: String) async throws -> ServerConfig {
    let base = authServerURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    try URLValidator.throwIfInvalid(base)
    guard let url = URL(string: "\(base)/api/config") else {
        throw APIError.invalidResponse
    }
    let (data, response) = try await URLSession.shared.data(from: url)
    guard let httpResponse = response as? HTTPURLResponse,
          (200 ... 299).contains(httpResponse.statusCode)
    else {
        throw APIError.invalidResponse
    }
    return try JSONDecoder().decode(ServerConfig.self, from: data)
}
