import Foundation
import os

/// Talks to the Pablo backend for goal-based navigation intelligence.
///
/// The client sends the current page DOM + a goal (no PHI). The backend
/// constructs an LLM prompt and returns the next action to take.
@MainActor
final class NavigationAPIClient {
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "NavigationAPIClient")
    private let baseURL: String
    private let getToken: @Sendable () async throws -> String
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: String, getToken: @escaping @Sendable () async throws -> String) {
        self.baseURL = baseURL
        self.getToken = getToken

        self.decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        self.encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    // MARK: - Goal-based navigation

    /// Asks the backend LLM to decide the next navigation action.
    ///
    /// The client sends the current page URL + DOM snapshot (PHI stripped)
    /// and a goal like "Navigate to SOAP note form for appointment at 8:00 PM on March 23".
    /// The backend constructs the LLM prompt internally — the client cannot send arbitrary prompts.
    func navigate(request: GoalNavigationRequest) async throws -> GoalNavigationResponse {
        let url = try buildURL("/api/ehr-navigate")
        var httpRequest = try await authenticatedRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await URLSession.shared.data(for: httpRequest)
        try validateResponse(response)
        return try decoder.decode(GoalNavigationResponse.self, from: data)
    }

    // MARK: - Helpers

    private func buildURL(_ path: String) throws -> URL {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw NavigationAPIError.invalidURL(path: path)
        }
        return url
    }

    private func authenticatedRequest(url: URL) async throws -> URLRequest {
        let token = try await getToken()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("pablo-companion-macos/1.0", forHTTPHeaderField: "X-Client-Type")
        return request
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NavigationAPIError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 200 ... 299:
            return
        case 401:
            throw NavigationAPIError.notAuthenticated
        case 422:
            throw NavigationAPIError.validationError
        case 429:
            throw NavigationAPIError.rateLimited
        case 502:
            throw NavigationAPIError.llmUnavailable
        default:
            throw NavigationAPIError.serverError(code: httpResponse.statusCode)
        }
    }
}

// MARK: - Errors

enum NavigationAPIError: LocalizedError {
    case invalidURL(path: String)
    case invalidResponse
    case notAuthenticated
    case validationError
    case rateLimited
    case llmUnavailable
    case serverError(code: Int)

    var errorDescription: String? {
        switch self {
        case let .invalidURL(path):
            "Invalid API URL: \(path)"
        case .invalidResponse:
            "Invalid response from server."
        case .notAuthenticated:
            "Not authenticated. Please sign in."
        case .validationError:
            "Request validation failed. Check the request format."
        case .rateLimited:
            "Too many navigation requests. Please try again later."
        case .llmUnavailable:
            "AI navigation service is temporarily unavailable."
        case let .serverError(code):
            "Server error (\(code)). Please try again."
        }
    }
}
