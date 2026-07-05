import Foundation
import PracticeClientCore

/// Subscription status and grace extension endpoints.
extension APIClient {
    func fetchSubscriptionStatus() async throws -> SubscriptionInfo {
        let request = try await buildRequest("GET", path: "/api/users/me/status")
        let (data, response) = try await URLSession.shared.data(for: request)
        // Shared error mapper so a 401 here fires onAuthRejected — the 10-min
        // subscription poll is often the first call to see a dead session.
        try mapHTTPErrors(data: data, response: response)

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
        let request = try await buildRequest("POST", path: "/api/users/me/subscription/extend")
        let (data, response) = try await URLSession.shared.data(for: request)
        try mapHTTPErrors(data: data, response: response)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SubscriptionInfo.self, from: data)
    }
}
