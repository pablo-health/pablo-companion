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
    /// The web start already asked "No consent on file" and the clinician chose
    /// to record anyway. False from a server that predates the field.
    let aiConsentPrompted: Bool

    enum CodingKeys: String, CodingKey {
        case appointmentId = "appointment_id"
        case patientName = "patient_name"
        case videoUrl = "video_url"
        case sessionId = "session_id"
        case aiConsentPrompted = "ai_consent_prompted"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appointmentId = try container.decode(String.self, forKey: .appointmentId)
        patientName = try container.decodeIfPresent(String.self, forKey: .patientName)
        videoUrl = try container.decodeIfPresent(String.self, forKey: .videoUrl)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        aiConsentPrompted = try container.decodeIfPresent(Bool.self, forKey: .aiConsentPrompted) ?? false
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
