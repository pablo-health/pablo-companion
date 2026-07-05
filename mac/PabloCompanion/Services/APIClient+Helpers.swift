import Foundation
import PracticeClientCore

extension APIClient {
    /// Maps non-2xx HTTP status codes to typed `PabloError` values.
    func mapHTTPErrors(data: Data, response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        let statusCode = httpResponse.statusCode

        guard !(200 ... 299).contains(statusCode) else { return }

        let rawBody = String(data: data, encoding: .utf8) ?? "Unknown error"
        let envelope = APIClient.parseErrorEnvelope(data)
        let message = envelope?.message ?? rawBody

        switch statusCode {
        case 401:
            // Surface the rejection to the auth layer (sign-out + re-auth
            // prompt) before throwing. IDLE_TIMEOUT means the server-side
            // idle session expired — a token refresh cannot revive it.
            onAuthRejected?(envelope?.code == Self.idleTimeoutCode)
            throw PabloError.unauthenticated
        case 403:
            throw PabloError.forbidden
        case 404:
            throw PabloError.notFound(resource: message)
        case 409:
            throw PabloError.conflictState(message: message)
        case 426:
            throw PabloError.updateRequired(message: message)
        default:
            throw PabloError.apiClient(
                statusCode: UInt16(statusCode),
                message: message,
                code: envelope?.code
            )
        }
    }

    /// Parses the standard backend error envelope
    /// (`{error: {code, message, details}}`) into a `(message, code)` pair.
    /// Returns nil for bodies that don't match the envelope shape.
    static func parseErrorEnvelope(_ data: Data) -> (message: String?, code: String?)? {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let err = json?["error"] as? [String: Any] else { return nil }
        return (err["message"] as? String, err["code"] as? String)
    }

    // MARK: - Version Comparison

    /// Semver comparison: returns `true` if `lhs` is strictly less than `rhs`.
    static func isVersion(_ lhs: String, lessThan rhs: String) -> Bool {
        let lhsParts = lhs.split(separator: ".").compactMap { Int($0) }
        let rhsParts = rhs.split(separator: ".").compactMap { Int($0) }

        for i in 0 ..< max(lhsParts.count, rhsParts.count) {
            let left = i < lhsParts.count ? lhsParts[i] : 0
            let right = i < rhsParts.count ? rhsParts[i] : 0
            if left < right { return true }
            if left > right { return false }
        }
        return false
    }
}
