import Foundation
import os

/// Talks to the Pablo backend for two things only:
///   1. Cached route CRUD (shared across all therapists per EHR system)
///   2. LLM navigation fallback (when the accessibility tree doesn't match)
///
/// The client never sends patient names or PHI to these endpoints.
/// PHI is stripped by EHRNavigator before calling `getNavigationAction`.
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

    // MARK: - Route cache

    /// Fetches the cached navigation route for an EHR system.
    /// These routes are shared — one therapist's successful navigation teaches all.
    func fetchRoute(ehrSystem: String) async throws -> CachedRoute {
        let url = try buildURL("/api/ehr-routes/\(ehrSystem)")
        var request = try await authenticatedRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        return try decoder.decode(CachedRoute.self, from: data)
    }

    /// Reports a route step update after a successful LLM-assisted recovery.
    /// The backend merges this into the shared route for this EHR system.
    func reportRouteUpdate(
        ehrSystem: String,
        stepIndex: Int,
        newSelector: String,
        newFingerprint: String
    ) async throws {
        let url = try buildURL("/api/ehr-routes/\(ehrSystem)/steps/\(stepIndex)")
        var request = try await authenticatedRequest(url: url)
        request.httpMethod = "PATCH"

        let body: [String: String] = [
            "selector": newSelector,
            "a11y_fingerprint": newFingerprint,
        ]
        request.httpBody = try encoder.encode(body)

        let (_, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        logger.info("Route step \(stepIndex) updated for \(ehrSystem)")
    }

    /// Saves a newly learned route to the backend so all therapists benefit.
    func saveRoute(route: CachedRoute) async throws {
        let url = try buildURL("/api/ehr-routes/\(route.ehrSystem)")
        var request = try await authenticatedRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = try encoder.encode(route)

        let (_, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        logger.info("Saved learned route for \(route.ehrSystem) with \(route.steps.count) steps")
    }

    // MARK: - LLM navigation fallback

    /// Asks the backend LLM to figure out the next navigation action.
    ///
    /// Called only when the cached route's accessibility fingerprint doesn't
    /// match the current page. The accessibility tree is PHI-stripped by the
    /// caller — no patient names reach this endpoint.
    ///
    /// The backend constructs the LLM prompt internally from the structured
    /// request. The client cannot send arbitrary prompts.
    func getNavigationAction(request navigationRequest: NavigationRequest) async throws -> NavigationAction {
        let url = try buildURL("/api/ehr-navigate")
        var request = try await authenticatedRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(navigationRequest)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        return try decoder.decode(NavigationAction.self, from: data)
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
        case 404:
            throw NavigationAPIError.routeNotFound
        case 429:
            throw NavigationAPIError.rateLimited
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
    case routeNotFound
    case rateLimited
    case serverError(code: Int)

    var errorDescription: String? {
        switch self {
        case let .invalidURL(path):
            "Invalid API URL: \(path)"
        case .invalidResponse:
            "Invalid response from server."
        case .notAuthenticated:
            "Not authenticated. Please sign in."
        case .routeNotFound:
            "No cached route found for this EHR system."
        case .rateLimited:
            "Too many navigation requests. Please try again later."
        case let .serverError(code):
            "Server error (\(code)). Please try again."
        }
    }
}
