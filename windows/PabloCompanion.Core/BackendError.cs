using System.Text.Json;

namespace PabloCompanion.Core;

/// <summary>
/// The one reading of a backend error response, shared by every client exception
/// (<see cref="SessionUploadException"/>, <see cref="ConsentRequestException"/>,
/// and the app's <c>PabloException</c>).
///
/// Exception messages end up in the crash log and, in places, on screen, so they
/// carry only the HTTP status and the backend's structured <c>error.code</c>. They
/// never carry the response body or the envelope's free-text <c>message</c>, either
/// of which can echo patient data back.
/// </summary>
public static class BackendError
{
    /// <summary>
    /// <c>HTTP 409</c>, or <c>HTTP 409 [CODE]</c> when the backend sent an
    /// <c>error.code</c>. PHI-safe by construction.
    /// </summary>
    public static string Describe(int statusCode, string? code) =>
        $"HTTP {statusCode}" + (code is null ? "" : $" [{code}]");

    /// <summary>
    /// Parses the standard error envelope (<c>{error: {code, message, details}}</c>)
    /// into its code and string-valued <c>details</c>. Null for a body that is not
    /// the envelope.
    /// </summary>
    public static (string? Code, IReadOnlyDictionary<string, string> Details)? ReadEnvelope(string? body)
    {
        if (string.IsNullOrWhiteSpace(body)) return null;
        try
        {
            using var doc = JsonDocument.Parse(body);
            if (doc.RootElement.ValueKind != JsonValueKind.Object ||
                !doc.RootElement.TryGetProperty("error", out var error) ||
                error.ValueKind != JsonValueKind.Object) return null;

            var code = error.TryGetProperty("code", out var c) && c.ValueKind == JsonValueKind.String
                ? c.GetString() : null;
            var details = new Dictionary<string, string>(StringComparer.Ordinal);
            if (error.TryGetProperty("details", out var d) && d.ValueKind == JsonValueKind.Object)
            {
                foreach (var property in d.EnumerateObject())
                {
                    if (property.Value.ValueKind == JsonValueKind.String)
                        details[property.Name] = property.Value.GetString() ?? "";
                }
            }
            return (code, details);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>The envelope's <c>error.code</c>, or null when absent or not an envelope.</summary>
    public static string? ReadCode(string? body) => ReadEnvelope(body)?.Code;
}
