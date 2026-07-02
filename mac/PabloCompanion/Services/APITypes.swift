import Foundation
import PracticeClientCore

// MARK: - Multipart Data Helper

/// A single field in a multipart/form-data request body.
struct MultipartFilePart {
    let fieldName: String
    let fileName: String
    let mimeType: String
    let data: Data
}

func buildMultipartBody(parts: [MultipartFilePart], boundary: String) -> Data {
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

/// Context returned by `POST /api/launch/redeem` after a launch intent is
/// successfully consumed. `patient_name` is PHI — only surfaced inside the
/// app's confirmation UI, never logged.
struct LaunchRedemption: Codable, Sendable {
    let appointmentId: String
    let patientName: String?
    let videoUrl: String?
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case appointmentId = "appointment_id"
        case patientName = "patient_name"
        case videoUrl = "video_url"
        case sessionId = "session_id"
    }
}

/// Server configuration returned by the Pablo backend's /api/config endpoint.
struct ServerConfig: Codable, Sendable {
    let apiUrl: String
    let firebaseApiKey: String?
    let firebaseProjectId: String?
}

/// Fetches runtime configuration from the Pablo backend.
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
