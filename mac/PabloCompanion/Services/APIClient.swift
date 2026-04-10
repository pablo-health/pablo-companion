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

    // MARK: - Audio Upload (native URLSession — not via Rust core)

    /// Uploads therapist and client audio files to the backend for server-side transcription.
    /// Uses native URLSession multipart/form-data since this endpoint is not in pablo-core.
    ///
    /// Writes the multipart body to a temp file to avoid loading large audio files
    /// (potentially hundreds of MB) entirely into memory simultaneously.
    ///
    /// - Parameters:
    ///   - sessionId: The backend session UUID (must be in `recording_complete` status).
    ///   - therapistAudioURL: Path to the mic PCM/WAV sidecar file.
    ///   - clientAudioURL: Path to the system audio PCM/WAV sidecar file (optional).
    ///   - onProgress: Progress callback (0.0–1.0). Simulated since URLSession upload
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
        request.timeoutInterval = 300

        onProgress(0.1)

        // Write the multipart body to a temp file instead of holding everything in RAM.
        // For 60-min sessions each sidecar can be ~330 MB; holding two in memory risks OOM.
        let tempBodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pablo_upload_\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tempBodyURL) }

        try writeMultipartBody(
            to: tempBodyURL,
            boundary: boundary,
            therapistAudioURL: therapistAudioURL,
            clientAudioURL: clientAudioURL
        )

        onProgress(0.3)

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: tempBodyURL)

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

/// Writes a multipart/form-data body to a file, streaming each audio file in chunks
/// to avoid loading the full payload into memory. Each audio file is read in 1 MB chunks.
private func writeMultipartBody(
    to outputURL: URL,
    boundary: String,
    therapistAudioURL: URL,
    clientAudioURL: URL?
) throws {
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: outputURL)
    defer { try? handle.close() }

    let chunkSize = 1_048_576 // 1 MB

    func writeFilePart(fieldName: String, fileURL: URL) throws {
        let header = "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileURL.lastPathComponent)\"\r\n"
            + "Content-Type: audio/wav\r\n\r\n"
        handle.write(Data(header.utf8))

        let inputHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? inputHandle.close() }
        while autoreleasepool(invoking: {
            let chunk = inputHandle.readData(ofLength: chunkSize)
            if chunk.isEmpty { return false }
            handle.write(chunk)
            return true
        }) {}

        handle.write(Data("\r\n".utf8))
    }

    try writeFilePart(fieldName: "therapist_audio", fileURL: therapistAudioURL)

    if let clientAudioURL, FileManager.default.fileExists(atPath: clientAudioURL.path) {
        try writeFilePart(fieldName: "client_audio", fileURL: clientAudioURL)
    }

    handle.write(Data("--\(boundary)--\r\n".utf8))
}
