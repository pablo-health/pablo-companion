using System.Security.Cryptography;

namespace PabloCompanion.Services;

/// <summary>
/// Manages the per-install P-256 device key used for device-bound auth.
///
/// The key is created once at enrollment and persisted (PKCS#8, base64) in the
/// credential vault so it survives sign-out/sign-in — the same install id and key
/// identify this device for its lifetime. Today the key is software-backed
/// (<c>key_storage = "software"</c>); a future hardening pass moves it to the TPM
/// via the Microsoft Platform Crypto Provider. Per-request DPoP proof signing is a
/// later stage and is intentionally NOT wired here — this service only mints the
/// key and exports its public JWK for enrollment.
/// </summary>
public sealed class DeviceKeyService
{
    private const string PrivateKeyVaultKey = "deviceKeyPkcs8";

    /// <summary>
    /// Storage backing for the device key, reported to the backend at enrollment.
    /// Software (DPAPI/vault-protected) until hardware-backed keys land.
    /// </summary>
    public const string KeyStorage = "software";

    private readonly CredentialManager _credentials;

    public DeviceKeyService(CredentialManager credentials)
    {
        _credentials = credentials;
    }

    /// <summary>
    /// Returns the public P-256 key as an RFC 7517 JWK (<c>kty/crv/x/y</c>),
    /// creating and persisting the keypair on first use. The dictionary shape
    /// (<c>dict[str, str]</c>) matches the backend enrollment contract exactly;
    /// the backend computes the RFC 7638 thumbprint itself, so no <c>kid</c>/<c>jkt</c>
    /// is sent.
    /// </summary>
    public Dictionary<string, string> GetOrCreatePublicJwk()
    {
        using var ecdsa = LoadOrCreateKey();
        var parameters = ecdsa.ExportParameters(includePrivateParameters: false);

        // P-256 field elements are 32 bytes; export already returns fixed-width
        // big-endian Q.X / Q.Y for the named curve.
        return new Dictionary<string, string>
        {
            ["kty"] = "EC",
            ["crv"] = "P-256",
            ["x"] = Base64Url(parameters.Q.X!),
            ["y"] = Base64Url(parameters.Q.Y!),
        };
    }

    private ECDsa LoadOrCreateKey()
    {
        var stored = _credentials.GetValue(PrivateKeyVaultKey);
        if (!string.IsNullOrEmpty(stored))
        {
            try
            {
                var ecdsa = ECDsa.Create();
                ecdsa.ImportPkcs8PrivateKey(Convert.FromBase64String(stored), out _);
                return ecdsa;
            }
            catch (Exception)
            {
                // Corrupt / unreadable — regenerate below.
            }
        }

        var created = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var pkcs8 = created.ExportPkcs8PrivateKey();
        _credentials.SetValue(PrivateKeyVaultKey, Convert.ToBase64String(pkcs8));
        return created;
    }

    private static string Base64Url(byte[] bytes)
        => Convert.ToBase64String(bytes).Replace('+', '-').Replace('/', '_').TrimEnd('=');
}
