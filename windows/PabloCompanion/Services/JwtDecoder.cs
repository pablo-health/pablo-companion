using System.Text;
using System.Text.Json;

namespace PabloCompanion.Services;

/// <summary>
/// Minimal JWT decoder for extracting email and expiry from Firebase ID tokens.
/// No signature verification — the backend verifies tokens.
/// </summary>
public static class JwtDecoder
{
    public static string? GetEmail(string jwt)
    {
        var payload = DecodePayload(jwt);
        if (payload == null) return null;

        if (payload.Value.TryGetProperty("email", out var email))
            return email.GetString();

        return null;
    }

    public static DateTimeOffset? GetExpiry(string jwt)
    {
        var payload = DecodePayload(jwt);
        if (payload == null) return null;

        if (payload.Value.TryGetProperty("exp", out var exp))
            return DateTimeOffset.FromUnixTimeSeconds(exp.GetInt64());

        return null;
    }

    private static JsonElement? DecodePayload(string jwt)
    {
        var parts = jwt.Split('.');
        if (parts.Length != 3) return null;

        try
        {
            var padded = parts[1]
                .Replace('-', '+')
                .Replace('_', '/');

            switch (padded.Length % 4)
            {
                case 2: padded += "=="; break;
                case 3: padded += "="; break;
            }

            var bytes = Convert.FromBase64String(padded);
            var json = Encoding.UTF8.GetString(bytes);
            return JsonDocument.Parse(json).RootElement;
        }
        catch
        {
            return null;
        }
    }
}
