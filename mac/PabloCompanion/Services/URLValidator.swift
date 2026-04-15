import Foundation

enum URLValidator {
    /// Returns nil if valid, error string if invalid.
    static func validateScheme(_ urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "URL cannot be empty" }
        guard let url = URL(string: trimmed) else { return "Invalid URL format" }
        #if DEBUG
        if url.scheme == "https" { return nil }
        if url.scheme == "http", let host = url.host, host == "localhost" || host == "127.0.0.1" { return nil }
        return "URL must use HTTPS (or http://localhost / http://127.0.0.1 in debug builds)"
        #else
        if url.scheme == "https" { return nil }
        return "URL must use HTTPS"
        #endif
    }

    static func throwIfInvalid(_ urlString: String) throws {
        if let error = validateScheme(urlString) {
            throw URLValidationError.invalidScheme(error)
        }
    }
}

enum URLValidationError: LocalizedError {
    case invalidScheme(String)

    var errorDescription: String? {
        switch self {
        case let .invalidScheme(msg):
            msg
        }
    }
}
