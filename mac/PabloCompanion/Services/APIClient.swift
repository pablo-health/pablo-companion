import Foundation
import os

/// Native URLSession-based API client for the Pablo backend.
/// Replaces the previous Rust FFI (pablo-core) delegation with direct HTTP calls.
@MainActor
final class APIClient {
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "APIClient")

    nonisolated let baseURL: URL
    nonisolated private let baseURLString: String

    /// Optional closure to provide a Bearer token for authenticated requests.
    var getToken: (@Sendable () async throws -> String)?

    private static let clientVersion = "1.0.0"
    private static let minServerVersion = "1.0.0"

    private static let fallbackURL: URL = {
        // Static string — guaranteed to parse. Extracted to avoid force-unwrap at call site.
        guard let url = URL(string: "https://api.pablo.health") else {
            preconditionFailure("Hardcoded fallback URL is invalid")
        }
        return url
    }()

    private nonisolated let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private nonisolated let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
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
        if let minClientVersions = json["min_client_versions"] as? [String: Any],
           let macosMin = minClientVersions["macos"] as? String {
            minClientVersion = macosMin
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

    // MARK: - Recordings

    /// Uploads a recording file to the backend.
    func uploadRecording(
        fileURL: URL,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> UploadResponse {
        let token = try await requireToken()
        logger.info("Uploading recording file")

        onProgress(0.3)

        let endpoint = "\(baseURLString)/api/recordings/upload"
        guard let url = URL(string: endpoint) else {
            throw APIError.invalidResponse
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("pablo-companion-macos/1.0", forHTTPHeaderField: "X-Client-Type")
        request.setValue(Self.clientVersion, forHTTPHeaderField: "X-Client-Version")
        request.setValue("macos", forHTTPHeaderField: "X-Client-Platform")

        let fileData = try Data(contentsOf: fileURL)
        let parts = [MultipartFilePart(
            fieldName: "file",
            fileName: fileURL.lastPathComponent,
            mimeType: "application/octet-stream",
            data: fileData
        )]
        request.httpBody = buildMultipartBody(parts: parts, boundary: boundary)

        let (data, response) = try await URLSession.shared.data(for: request)
        try mapHTTPErrors(data: data, response: response)

        let decoded: UploadResponse = try handleResponse(data, response)

        onProgress(1.0)
        logger.info("Upload successful")
        return decoded
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

    // MARK: - Sessions

    /// Fetches today's sessions for the given timezone.
    func fetchTodaySessions(timezone: String) async throws -> [Session] {
        let encodedTZ = timezone.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? timezone
        let path = "/api/sessions/today?timezone=\(encodedTZ)"

        let request = try await buildRequest("GET", path: path)
        let (data, response) = try await URLSession.shared.data(for: request)
        try mapHTTPErrors(data: data, response: response)

        let listResponse: SessionListResponse = try handleResponse(data, response)
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

    // MARK: - Audio Upload (native URLSession multipart)

    /// Uploads therapist and client audio files to the backend for server-side transcription.
    /// Uses native URLSession multipart/form-data since this endpoint is not in pablo-core.
    ///
    /// - Parameters:
    ///   - sessionId: The backend session UUID (must be in `recording_complete` status).
    ///   - therapistAudioURL: Path to the mic PCM/WAV sidecar file.
    ///   - clientAudioURL: Path to the system audio PCM/WAV sidecar file (optional).
    ///   - onProgress: Progress callback (0.0-1.0). Simulated since URLSession upload
    ///     progress requires delegate-based uploads.
    /// - Returns: `AudioUploadResponse` with the session's new status.
    func uploadAudio(
        sessionId: String,
        therapistAudioURL: URL,
        clientAudioURL: URL?,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> AudioUploadResponse {
        let token = try await requireToken()

        let endpoint = "\(baseURLString)/api/sessions/\(sessionId)/upload-audio"
        guard let url = URL(string: endpoint) else {
            throw APIError.invalidResponse
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("pablo-companion-macos/1.0", forHTTPHeaderField: "X-Client-Type")

        onProgress(0.1)

        var parts = try [MultipartFilePart(
            fieldName: "therapist_audio",
            fileName: therapistAudioURL.lastPathComponent,
            mimeType: "audio/wav",
            data: Data(contentsOf: therapistAudioURL)
        )]

        onProgress(0.3)

        if let clientAudioURL, let clientData = try? Data(contentsOf: clientAudioURL) {
            parts.append(MultipartFilePart(
                fieldName: "client_audio",
                fileName: clientAudioURL.lastPathComponent,
                mimeType: "audio/wav",
                data: clientData
            ))
        }

        onProgress(0.5)

        request.httpBody = buildMultipartBody(parts: parts, boundary: boundary)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        onProgress(0.9)

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.serverError(statusCode: httpResponse.statusCode, message: message)
        }

        let decoded = try JSONDecoder().decode(AudioUploadResponse.self, from: data)
        onProgress(1.0)
        logger.info("Audio uploaded for session \(sessionId)")
        return decoded
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

    // MARK: - Private Helpers

    /// Builds a URLRequest with standard headers.
    /// - Parameters:
    ///   - method: HTTP method (GET, POST, PATCH, PUT, DELETE).
    ///   - path: API path (e.g. "/api/sessions"). Appended to `baseURLString`.
    ///   - authenticated: Whether to include the Authorization header. Defaults to `true`.
    /// - Returns: A configured URLRequest.
    private func buildRequest(
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
        }

        return request
    }

    /// Decodes a successful HTTP response body into the requested type.
    private func handleResponse<T: Decodable>(_ data: Data, _ response: URLResponse) throws -> T {
        do {
            return try jsonDecoder.decode(T.self, from: data)
        } catch {
            throw PabloError.jsonParse(message: "\(error.localizedDescription)")
        }
    }

    /// Maps non-2xx HTTP status codes to typed `PabloError` values.
    private func mapHTTPErrors(data: Data, response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        let statusCode = httpResponse.statusCode

        guard !(200 ... 299).contains(statusCode) else { return }

        let message = String(data: data, encoding: .utf8) ?? "Unknown error"

        switch statusCode {
        case 401:
            throw PabloError.unauthenticated
        case 403:
            throw PabloError.forbidden
        case 404:
            throw PabloError.notFound(resource: message)
        case 409:
            throw PabloError.conflictState(message: message)
        case 426:
            throw PabloError.updateRequired(message: message)
        default:
            throw PabloError.apiClient(statusCode: UInt16(statusCode), message: message)
        }
    }

    // MARK: - Version Comparison

    /// Semver comparison: returns `true` if `lhs` is strictly less than `rhs`.
    private static func isVersion(_ lhs: String, lessThan rhs: String) -> Bool {
        let lhsParts = lhs.split(separator: ".").compactMap { Int($0) }
        let rhsParts = rhs.split(separator: ".").compactMap { Int($0) }

        for i in 0 ..< max(lhsParts.count, rhsParts.count) {
            let l = i < lhsParts.count ? lhsParts[i] : 0
            let r = i < rhsParts.count ? rhsParts[i] : 0
            if l < r { return true }
            if l > r { return false }
        }
        return false
    }
}

// MARK: - Multipart Data Helper

/// A single field in a multipart/form-data request body.
private struct MultipartFilePart {
    let fieldName: String
    let fileName: String
    let mimeType: String
    let data: Data
}

private func buildMultipartBody(parts: [MultipartFilePart], boundary: String) -> Data {
    var body = Data()
    for part in parts {
        body.append(Data("--\(boundary)\r\n".utf8))
        body
            .append(Data("Content-Disposition: form-data; name=\"\(part.fieldName)\"; filename=\"\(part.fileName)\"\r\n"
                    .utf8))
        body.append(Data("Content-Type: \(part.mimeType)\r\n\r\n".utf8))
        body.append(part.data)
        body.append(Data("\r\n".utf8))
    }
    body.append(Data("--\(boundary)--\r\n".utf8))
    return body
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
