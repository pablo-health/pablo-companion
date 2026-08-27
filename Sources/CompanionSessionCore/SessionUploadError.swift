import Foundation

/// A non-2xx response from a session upload/status request.
///
/// Carries the HTTP status plus the backend's structured error envelope
/// (`{"error": {"code", "message"}}`) so callers can branch on `code` — most
/// importantly `INVALID_STATUS`, which drives the `recording_complete` self-heal.
/// The app maps this back onto its own `PabloError` at the call boundary so its
/// external error contract is unchanged.
public struct SessionUploadError: Error, Sendable {
    public let statusCode: Int
    /// Backend `error.code` (e.g. `"INVALID_STATUS"`), when present.
    public let code: String?
    /// Backend `error.message`, falling back to the raw body.
    public let message: String?

    public init(statusCode: Int, code: String?, message: String?) {
        self.statusCode = statusCode
        self.code = code
        self.message = message
    }

    /// Parses the standard backend error envelope
    /// (`{"error": {"code", "message", "details"}}`) into `(message, code)`.
    /// Returns `nil` for bodies that don't match the envelope shape.
    public static func parseEnvelope(_ data: Data) -> (message: String?, code: String?)? {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let err = json?["error"] as? [String: Any] else { return nil }
        return (err["message"] as? String, err["code"] as? String)
    }
}

extension SessionUploadError: LocalizedError, CustomStringConvertible {
    /// Without this, a plain `Error` struct bridges to
    /// "CompanionSessionCore.SessionUploadError error 1" — no status, no code,
    /// no message. That is what a failed 50-minute e2e reported, which is an
    /// expensive way to learn nothing: every field needed to diagnose it was
    /// already on the value and simply never printed.
    public var errorDescription: String? {
        description
    }

    public var description: String {
        var parts = ["upload failed: HTTP \(statusCode)"]
        if let code { parts.append("[\(code)]") }
        if let message, !message.isEmpty { parts.append("— \(message)") }
        return parts.joined(separator: " ")
    }
}
