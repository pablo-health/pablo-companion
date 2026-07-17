using System.Security.Cryptography;
using PabloCompanion.Core;

namespace PabloCompanion.Services;

/// <summary>
/// Manages the per-install P-256 device key used for device-bound auth.
///
/// The key is created once at enrollment and persisted (PKCS#8, base64) in the
/// credential vault so it survives sign-out/sign-in — the same install id and key
/// identify this device for its lifetime. Today the key is software-backed
/// (<c>key_storage = "software"</c>); a future hardening pass moves it to the TPM
/// via the Microsoft Platform Crypto Provider.
///
/// Two responsibilities: mint + export the public JWK for enrollment
/// (<see cref="GetOrCreatePublicJwk"/>), and sign a per-request DPoP proof with the
/// stored private key (<see cref="TryCreateProof"/>) so authenticated requests carry
/// proof-of-possession once the server enforces it.
/// </summary>
public sealed class DeviceKeyService
{
    private const string PrivateKeyVaultKey = "deviceKeyPkcs8";

    /// <summary>
    /// Storage backing for the device key, reported to the backend at enrollment.
    /// Software (DPAPI/vault-protected) until hardware-backed keys land.
    /// </summary>
    public const string KeyStorage = DeviceEnrollment.SoftwareKeyStorage;

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
        return DeviceEnrollment.PublicJwk(ecdsa);
    }

    /// <summary>
    /// Signs a DPoP proof for an authenticated backend request bound to
    /// <paramref name="method"/> + <paramref name="url"/>, returning the compact JWS.
    /// Returns <c>null</c> when this install has no device key yet (i.e. it has never
    /// enrolled) — the caller must then send NEITHER the proof nor the
    /// <c>X-Install-ID</c> header, since an install id without a matching proof is a
    /// guaranteed 401 under server enforcement.
    ///
    /// Unlike <see cref="GetOrCreatePublicJwk"/>, this does NOT mint a key: signing a
    /// proof for a never-enrolled device would attach proof material the backend has
    /// no public key to verify.
    /// </summary>
    public string? TryCreateProof(string method, string url)
    {
        using var ecdsa = LoadExistingKey();
        if (ecdsa is null) return null;
        return DpopProof.Create(ecdsa, method, url);
    }

    /// <summary>
    /// Loads the persisted device private key, or <c>null</c> if none is stored or the
    /// stored blob is unreadable. Never mints — see <see cref="TryCreateProof"/>.
    /// </summary>
    private ECDsa? LoadExistingKey()
    {
        var stored = _credentials.GetValue(PrivateKeyVaultKey);
        if (string.IsNullOrEmpty(stored)) return null;

        try
        {
            var ecdsa = ECDsa.Create();
            ecdsa.ImportPkcs8PrivateKey(Convert.FromBase64String(stored), out _);
            return ecdsa;
        }
        catch (Exception)
        {
            // Corrupt / unreadable — treat as not-enrolled rather than throwing.
            return null;
        }
    }

    private ECDsa LoadOrCreateKey()
    {
        var existing = LoadExistingKey();
        if (existing is not null) return existing;

        var created = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var pkcs8 = created.ExportPkcs8PrivateKey();
        _credentials.SetValue(PrivateKeyVaultKey, Convert.ToBase64String(pkcs8));
        return created;
    }
}
