import Foundation

/// Errors surfaced by the practice REST client.
public enum APIError: LocalizedError {
    case invalidResponse
    case serverError(statusCode: Int, message: String)
    case notAuthenticated

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Invalid response from server."
        case let .serverError(code, message):
            "Server error (\(code)): \(message)"
        case .notAuthenticated:
            "Not authenticated. Please sign in."
        }
    }
}
