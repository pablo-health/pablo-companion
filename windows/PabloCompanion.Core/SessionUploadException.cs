namespace PabloCompanion.Core;

/// <summary>
/// A non-2xx response from the session upload / status routes.
///
/// Carries the backend's structured <c>error.code</c> alongside the HTTP status so
/// callers can branch on semantic conditions — notably
/// <see cref="InvalidStatusCode"/>, which drives the upload self-heal — without
/// pattern-matching on human-readable messages. For an HTTP failure the message
/// is <see cref="BackendError.Describe"/>: status and code only, never the body.
///
/// The mirror of macOS <c>SessionUploadError</c> in <c>CompanionSessionCore</c>.
/// The WinUI app translates this into its own <c>PabloException</c> at the
/// APIClient boundary, so app-level callers see no change.
/// </summary>
public sealed class SessionUploadException : Exception
{
    /// <summary>The backend error code returned when a session isn't in an uploadable status.</summary>
    public const string InvalidStatusCode = "INVALID_STATUS";

    /// <summary>HTTP status code, or -1 when the failure was not an HTTP response.</summary>
    public int StatusCode { get; }

    /// <summary>Structured <c>error.code</c> from the response envelope; null when absent.</summary>
    public string? ErrorCode { get; }

    public SessionUploadException(int statusCode, string? errorCode, string message)
        : base(message)
    {
        StatusCode = statusCode;
        ErrorCode = errorCode;
    }

    /// <summary>
    /// Whether this is the backend rejecting an upload because the session is still
    /// in <c>recording</c> — the one failure the upload path heals rather than retries.
    /// </summary>
    public bool IsInvalidStatus => StatusCode == 400 && ErrorCode == InvalidStatusCode;
}
