using System.Security.Cryptography;
using System.Text;

namespace PabloCompanion.Core;

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
    /// Assembles the enrollment payload sent alongside the auth code. Field names
    /// match the backend's enrollment contract exactly (the backend requires the
    /// JWK + key_storage, so they are always sent); <c>os_version</c> and
    /// <c>hostname_hash</c> are derived from the local machine.
    ///
    /// Takes the identity material as plain values rather than reading it from the
    /// credential vault, so this stays usable by a headless runner signing with an
    /// ephemeral in-memory key — and so this assembly never depends on WinRT.
    /// </summary>
    /// <param name="installId">Stable per-install id. The app supplies the vault-persisted
    /// one; a runner supplies a fresh id per run.</param>
    /// <param name="devicePublicKeyJwk">Device public key as an RFC 7517 JWK (<c>kty/crv/x/y</c>).</param>
    /// <param name="keyStorage">How the private key is held, e.g. <c>"software"</c>.</param>
    public static Dictionary<string, object?> BuildPayload(
        string installId,
        IReadOnlyDictionary<string, string> devicePublicKeyJwk,
        string keyStorage)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(installId);
        ArgumentNullException.ThrowIfNull(devicePublicKeyJwk);
        ArgumentException.ThrowIfNullOrWhiteSpace(keyStorage);

        return new Dictionary<string, object?>
        {
            ["install_id"] = installId,
            ["platform"] = Platform,
            ["os_version"] = Environment.OSVersion.Version.ToString(),
            ["hostname_hash"] = HashHostname(Environment.MachineName),
            ["device_public_key_jwk"] = devicePublicKeyJwk,
            ["key_storage"] = keyStorage,
        };
    }
}
