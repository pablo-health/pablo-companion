import CompanionSessionCore
import Foundation
import PracticeClientCore

// The multipart body helpers (`MultipartFilePart` / `buildMultipartBody`) now
// live in `CompanionSessionCore` so the app and the headless harness share one
// upload wire format. Imported above.

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
