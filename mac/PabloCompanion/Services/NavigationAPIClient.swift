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
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.getToken = getToken
        logger.info("NavigationAPIClient baseURL: \(baseURL)")

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
        logger.info("EHR navigate → \(url.absoluteString)")
        var httpRequest = try await authenticatedRequest(url: url)
        httpRequest.httpMethod = "POST"
        let requestBody = try encoder.encode(request)
        httpRequest.httpBody = requestBody

        // Log outgoing request (DOM truncated for readability)
        if let json = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any] {
            let dom = (json["dom_snapshot"] as? String) ?? ""
            logger.info("""
            ➡️ REQUEST to \(url.absoluteString)
              ehr_system: \(json["ehr_system"] as? String ?? "?")
              goal: \(json["goal"] as? String ?? "?")
              current_url: \(json["current_url"] as? String ?? "?")
              dom_snapshot: \(dom.prefix(200))… (\(dom.count) chars)
              previous_actions: \(json["previous_actions"] as? [[String: Any]] ?? [])
              failed_action: \(json["failed_action"] as? String ?? "nil")
            """)
        }

        let (data, response) = try await URLSession.shared.data(for: httpRequest)

        // Log response
        if let httpResp = response as? HTTPURLResponse {
            let body = String(data: data.prefix(1000), encoding: .utf8) ?? "<binary>"
            if httpResp.statusCode == 200 {
                logger.info("⬅️ RESPONSE 200:\n\(body)")
            } else {
                logger.error("⬅️ RESPONSE \(httpResp.statusCode):\n\(body)")
            }
        }

        try validateResponse(response)
        let decoded = try decoder.decode(GoalNavigationResponse.self, from: data)

        logger.info("""
        ⬅️ PARSED RESPONSE:
          action: \(decoded.action.rawValue)
          selector: \(decoded.selector)
          reasoning: \(decoded.reasoning)
          confidence: \(decoded.confidence)
          isOnTargetPage: \(decoded.isOnTargetPage)
          formFields: \(decoded.formFields?.description ?? "nil")
          alternativePlan: \(decoded.alternativePlan ?? "nil")
        """)

        return decoded
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
        request.setValue(AppConstants.appVersion, forHTTPHeaderField: "X-Client-Version")
        request.setValue("macos", forHTTPHeaderField: "X-Client-Platform")
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
        case 426:
            throw NavigationAPIError.updateRequired
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
    case updateRequired
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
        case .updateRequired:
            "This app version is no longer supported. Please update to continue."
        case .rateLimited:
            "Too many navigation requests. Please try again later."
        case .llmUnavailable:
            "AI navigation service is temporarily unavailable."
        case let .serverError(code):
            "Server error (\(code)). Please try again."
        }
    }
}
