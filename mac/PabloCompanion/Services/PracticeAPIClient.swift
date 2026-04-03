import Foundation
import os

/// REST client for practice mode endpoints. Uses native URLSession (not Rust core)
/// since practice mode is a new feature not yet in pablo-core.
@MainActor
final class PracticeAPIClient {
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "PracticeAPIClient")

    var baseURL = "https://api.pablo.health"
    var getToken: (@Sendable () async throws -> String)?

    private func requireToken() async throws -> String {
        guard let getToken else {
            throw APIError.notAuthenticated
        }
        return try await getToken()
    }

    private func makeRequest(
        _ path: String, method: String = "GET", body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let token = try await requireToken()
        let urlString = "\(baseURL)\(path)"
        guard let url = URL(string: urlString) else {
            throw APIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("pablo-companion-macos/\(AppConstants.appVersion)", forHTTPHeaderField: "X-Client-Type")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.serverError(statusCode: httpResponse.statusCode, message: message)
        }
        return (data, httpResponse)
    }

    // MARK: - Topics

    func fetchTopics() async throws -> [PracticeTopic] {
        let (data, _) = try await makeRequest("/api/practice/topics")
        let response = try JSONDecoder().decode(PracticeTopicListResponse.self, from: data)
        logger.info("Fetched \(response.total) practice topics")
        return response.data
    }

    // MARK: - Sessions

    func createSession(topicId: String) async throws -> PracticeSessionResponse {
        let body = try JSONEncoder().encode(["topic_id": topicId])
        let (data, _) = try await makeRequest("/api/practice/sessions", method: "POST", body: body)
        let session = try JSONDecoder().decode(PracticeSessionResponse.self, from: data)
        logger.info("Created practice session \(session.sessionId)")
        return session
    }

    func endSession(sessionId: String) async throws {
        _ = try await makeRequest("/api/practice/sessions/\(sessionId)/end", method: "POST")
        logger.info("Ended practice session \(sessionId) via REST")
    }

    /// Builds the WebSocket URL using a single-use ticket from session creation.
    /// Forces IPv4 (127.0.0.1) for localhost to avoid URLSessionWebSocketTask IPv6 issues.
    func webSocketURL(ticket: String) -> URL? {
        let wsBase = baseURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
            .replacingOccurrences(of: "://localhost", with: "://127.0.0.1")
        return URL(string: "\(wsBase)/api/practice/ws?ticket=\(ticket)")
    }

    /// Fetches a fresh single-use WebSocket ticket for reconnection.
    /// Tickets expire after 30 seconds and can only be used once.
    func fetchTicket() async throws -> String {
        let (data, _) = try await makeRequest("/api/practice/ws-ticket", method: "POST")
        let response = try JSONDecoder().decode(TicketResponse.self, from: data)
        return response.ticket
    }
}
