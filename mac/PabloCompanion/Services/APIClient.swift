import Foundation
import os

/// A simple URLSession wrapper for communicating with the sample backend.
@MainActor
final class APIClient {
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "APIClient")

    nonisolated let baseURL: URL
    private let clientType = "therapyrecorder-macos/1.0"

    /// Optional closure to provide a Bearer token for authenticated requests.
    var getToken: (@Sendable () async throws -> String)?

    init(baseURL: String = "http://localhost:8000") {
        guard let url = URL(string: baseURL) else {
            preconditionFailure("APIClient initialized with invalid base URL: \(baseURL)")
        }
        self.baseURL = url
    }

    /// Checks if the backend is reachable.
    func healthCheck() async throws -> Bool {
        let url = baseURL.appendingPathComponent("health")
        var request = URLRequest(url: url)
        request.setValue(clientType, forHTTPHeaderField: "X-Client-Type")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return false }
        return httpResponse.statusCode == 200
    }

    /// Uploads a recording file to the backend via multipart form data.
    /// Returns a progress-reporting async stream and the final upload response.
    func uploadRecording(
        fileURL: URL,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> UploadResponse {
        let url = baseURL.appendingPathComponent("api/recordings/upload")

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(clientType, forHTTPHeaderField: "X-Client-Type")

        // Inject Bearer token if available
        if let getToken {
            let token = try await getToken()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let fileData = try Data(contentsOf: fileURL)
        let body = createMultipartBody(
            fileData: fileData,
            fileName: fileURL.lastPathComponent,
            boundary: boundary
        )
        request.httpBody = body

        logger.info("Uploading \(fileURL.lastPathComponent) (\(fileData.count) bytes)")

        // Simulate incremental progress since URLSession data tasks
        // don't provide upload progress natively without a delegate.
        onProgress(0.3)

        let (data, response) = try await URLSession.shared.data(for: request)

        onProgress(1.0)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("Upload failed: \(httpResponse.statusCode) — \(body)")
            throw APIError.serverError(statusCode: httpResponse.statusCode, message: body)
        }

        let decoded = try JSONDecoder().decode(UploadResponse.self, from: data)
        logger.info("Upload successful: \(decoded.id)")
        return decoded
    }

    /// Fetches a paginated list of patients from the backend.
    func fetchPatients(
        search: String = "",
        page: Int = 1,
        pageSize: Int = 50
    ) async throws -> PatientListResponse {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("api/patients"),
            resolvingAgainstBaseURL: false
        ) else {
            throw APIError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "search", value: search),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page_size", value: String(pageSize)),
        ]

        guard let requestURL = components.url else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: requestURL)
        request.setValue(clientType, forHTTPHeaderField: "X-Client-Type")

        if let getToken {
            let token = try await getToken()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("Fetch patients failed: \(httpResponse.statusCode) — \(body)")
            throw APIError.serverError(statusCode: httpResponse.statusCode, message: body)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PatientListResponse.self, from: data)
    }

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

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Invalid response from server."
        case let .serverError(code, message):
            "Server error (\(code)): \(message)"
        }
    }
}

struct UploadResponse: Codable, Sendable {
    let id: String
    let status: String
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
