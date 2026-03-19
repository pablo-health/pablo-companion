namespace PabloCompanion.Services;

/// <summary>
/// Validates and normalizes server URLs. Mirrors URLValidator.swift on macOS.
/// </summary>
public static class UrlValidator
{
    public static string? ValidateScheme(string url)
    {
#if DEBUG
        if (url.StartsWith("https://", StringComparison.OrdinalIgnoreCase) ||
            url.StartsWith("http://localhost", StringComparison.OrdinalIgnoreCase))
        {
            return null; // Valid
        }
        return "URL must use HTTPS or http://localhost (debug)";
#else
        if (url.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            return null; // Valid
        }
        return "URL must use HTTPS";
#endif
    }

    /// <summary>
    /// Normalizes a server URL to just scheme + host + port (strips paths like /dashboard).
    /// Users often paste URLs like "https://example.com/dashboard" from their browser.
    /// </summary>
    public static string NormalizeToOrigin(string url)
    {
        if (Uri.TryCreate(url.TrimEnd('/'), UriKind.Absolute, out var uri))
        {
            return uri.GetLeftPart(UriPartial.Authority);
        }
        return url.TrimEnd('/');
    }

    public static void ThrowIfInvalid(string url)
    {
        var error = ValidateScheme(url);
        if (error != null)
        {
            throw new UriFormatException(error);
        }
    }
}
