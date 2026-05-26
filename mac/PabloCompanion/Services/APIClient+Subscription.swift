import Foundation
import PracticeClientCore

/// Subscription status and grace extension endpoints.
extension APIClient {
    func fetchSubscriptionStatus() async throws -> SubscriptionInfo {
        let token = try await requireToken()

        let endpoint = "\(baseURLString)/api/users/me/status"
        guard let url = URL(string: endpoint) else {
            throw APIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("pablo-companion-macos/1.0", forHTTPHeaderField: "X-Client-Type")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.serverError(statusCode: httpResponse.statusCode, message: message)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let wrapper = try decoder.decode(SubscriptionResponse.self, from: data)
        guard let info = wrapper.subscription else {
            throw APIError.invalidResponse
        }
        return info
    }

    /// Requests a one-time 1-day grace extension for a lapsed subscription.
    func extendSubscription() async throws -> SubscriptionInfo {
        let token = try await requireToken()

        let endpoint = "\(baseURLString)/api/users/me/subscription/extend"
        guard let url = URL(string: endpoint) else {
            throw APIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("pablo-companion-macos/1.0", forHTTPHeaderField: "X-Client-Type")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.serverError(statusCode: httpResponse.statusCode, message: message)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SubscriptionInfo.self, from: data)
    }
}
