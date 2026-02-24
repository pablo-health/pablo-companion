import Foundation
import os

/// Refreshes Firebase ID tokens using the securetoken.googleapis.com REST API.
struct TokenRefresher: Sendable {
    struct TokenResponse: Sendable {
        let idToken: String
        let refreshToken: String
        let expiresIn: Int
    }

    enum RefreshError: LocalizedError {
        case networkError(underlying: any Error)
        case invalidResponse
        case tokenRevoked
        case userDisabled
        case serverError(message: String)

        var errorDescription: String? {
            switch self {
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            case .invalidResponse:
                return "Invalid response from token service."
            case .tokenRevoked:
                return "Your session has expired. Please sign in again."
            case .userDisabled:
                return "This account has been disabled."
            case .serverError(let message):
                return "Token refresh failed: \(message)"
            }
        }
    }

    private let apiKey: String
    private let logger = Logger(subsystem: "com.macos-sample", category: "TokenRefresher")

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func refresh(using refreshToken: String) async throws -> TokenResponse {
        let urlString = "https://securetoken.googleapis.com/v1/token?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw RefreshError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "grant_type=refresh_token&refresh_token=\(refreshToken)"
            .data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RefreshError.networkError(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RefreshError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let errorMessage = (body?["error"] as? [String: Any])?["message"] as? String ?? "Unknown"

            switch errorMessage {
            case "TOKEN_EXPIRED", "INVALID_REFRESH_TOKEN":
                throw RefreshError.tokenRevoked
            case "USER_DISABLED":
                throw RefreshError.userDisabled
            default:
                throw RefreshError.serverError(message: errorMessage)
            }
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idToken = json["id_token"] as? String,
              let newRefreshToken = json["refresh_token"] as? String,
              let expiresInString = json["expires_in"] as? String,
              let expiresIn = Int(expiresInString)
        else {
            throw RefreshError.invalidResponse
        }

        logger.info("Token refreshed successfully, expires in \(expiresIn)s")
        return TokenResponse(
            idToken: idToken,
            refreshToken: newRefreshToken,
            expiresIn: expiresIn
        )
    }
}
