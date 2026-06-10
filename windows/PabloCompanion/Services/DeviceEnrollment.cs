using System.Security.Cryptography;
using System.Text;

namespace PabloCompanion.Services;

/// <summary>
/// Builds the device-enrollment fields piggy-backed on the OAuth code exchange
/// (<c>POST /api/auth/native/exchange</c>). The companion's first-launch OAuth IS
/// the device enrollment: the backend stores <c>(user_id, install_id, …)</c> so the
/// dashboard can later detect "this user has an enrolled companion" and hand off to it.
///
/// Privacy: the raw machine hostname never leaves the device — only a SHA-256 hex
/// digest is sent, so the backend can recognize a re-enroll of the same machine
/// without learning its name.
/// </summary>
public static class DeviceEnrollment
{
    /// <summary>The platform enum value the backend expects for Windows installs.</summary>
    public const string Platform = "windows";

    /// <summary>
    /// SHA-256 hex digest (lowercase) of the given hostname. Returns null for a
    /// null/blank hostname so the caller can omit the field rather than send a
    /// hash of the empty string.
    /// </summary>
    public static string? HashHostname(string? hostname)
    {
        if (string.IsNullOrWhiteSpace(hostname)) return null;

        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(hostname));
        return Convert.ToHexStringLower(bytes);
    }

    /// <summary>
    /// Assembles the enrollment payload sent alongside the auth code. Reads (and
    /// mints, if needed) the stable install id from <paramref name="credentials"/>,
    /// derives <c>os_version</c> / <c>hostname_hash</c> from the local machine, and
    /// includes the device public JWK + key-storage class from
    /// <paramref name="deviceKey"/>. Field names match the backend's enrollment
    /// contract exactly (the backend requires the JWK + key_storage, so they are
    /// always sent).
    /// </summary>
    public static Dictionary<string, object?> BuildPayload(
        CredentialManager credentials,
        DeviceKeyService deviceKey)
    {
        return new Dictionary<string, object?>
        {
            ["install_id"] = credentials.GetOrCreateInstallId(),
            ["platform"] = Platform,
            ["os_version"] = Environment.OSVersion.Version.ToString(),
            ["hostname_hash"] = HashHostname(Environment.MachineName),
            ["device_public_key_jwk"] = deviceKey.GetOrCreatePublicJwk(),
            ["key_storage"] = DeviceKeyService.KeyStorage,
        };
    }
}
