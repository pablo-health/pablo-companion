using Windows.Security.Credentials;

namespace PabloCompanion.Services;

/// <summary>
/// Stores and retrieves auth tokens using Windows Credential Manager (PasswordVault).
/// Mirrors KeychainManager.swift on macOS.
/// </summary>
public class CredentialManager
{
    private const string Resource = "PabloCompanion";

    private static readonly string[] AuthTokenKeys =
    [
        "idToken", "refreshToken", "userEmail",
        "authServerURL", "firebaseAPIKey", "backendAPIURL", "tenantID",
    ];

    private const string LegacyDeviceKeyName = "deviceEncryptionKey";

    /// <summary>
    /// The signed-in user's email, used to scope per-user encryption keys.
    /// Set after successful authentication.
    /// </summary>
    public string? ActiveUserEmail { get; set; }

    public string? GetValue(string key)
    {
        try
        {
            var vault = new PasswordVault();
            var credential = vault.Retrieve(Resource, key);
            credential.RetrievePassword();
            return credential.Password;
        }
        catch (Exception)
        {
            return null;
        }
    }

    public void SetValue(string key, string value)
    {
        var vault = new PasswordVault();
        // Remove existing credential if present
        try
        {
            var existing = vault.Retrieve(Resource, key);
            vault.Remove(existing);
        }
        catch (Exception) { /* Not found — ok */ }

        vault.Add(new PasswordCredential(Resource, key, value));
    }

    public void RemoveValue(string key)
    {
        try
        {
            var vault = new PasswordVault();
            var credential = vault.Retrieve(Resource, key);
            vault.Remove(credential);
        }
        catch (Exception) { /* Not found — ok */ }
    }

    // Convenience properties matching KeychainManager.swift

    public string? IdToken
    {
        get => GetValue("idToken");
        set { if (value != null) SetValue("idToken", value); else RemoveValue("idToken"); }
    }

    public string? RefreshToken
    {
        get => GetValue("refreshToken");
        set { if (value != null) SetValue("refreshToken", value); else RemoveValue("refreshToken"); }
    }

    public string? UserEmail
    {
        get => GetValue("userEmail");
        set { if (value != null) SetValue("userEmail", value); else RemoveValue("userEmail"); }
    }

    public string? AuthServerUrl
    {
        get => GetValue("authServerURL");
        set { if (value != null) SetValue("authServerURL", value); else RemoveValue("authServerURL"); }
    }

    public string? FirebaseApiKey
    {
        get => GetValue("firebaseAPIKey");
        set { if (value != null) SetValue("firebaseAPIKey", value); else RemoveValue("firebaseAPIKey"); }
    }

    public string? BackendApiUrl
    {
        get => GetValue("backendAPIURL");
        set { if (value != null) SetValue("backendAPIURL", value); else RemoveValue("backendAPIURL"); }
    }

    public string? TenantId
    {
        get => GetValue("tenantID");
        set { if (value != null) SetValue("tenantID", value); else RemoveValue("tenantID"); }
    }

    /// <summary>
    /// Stable per-install device identifier (UUIDv4), registered with the backend
    /// at enrollment and sent on the launch-redeem path via <c>X-Install-ID</c>.
    /// Deliberately NOT in <see cref="AuthTokenKeys"/>: it is a device identity that
    /// must survive sign-out/sign-in cycles, so <see cref="ClearAuthTokens"/> leaves
    /// it in place. Use <see cref="GetOrCreateInstallId"/> to read-or-mint it.
    /// </summary>
    public string? InstallId
    {
        get => GetValue("installId");
        set { if (value != null) SetValue("installId", value); else RemoveValue("installId"); }
    }

    /// <summary>
    /// Returns the persisted install id, minting a new UUIDv4 on first call and
    /// storing it. The value is stable for the lifetime of the install and survives
    /// sign-out (it is not cleared by <see cref="ClearAuthTokens"/>).
    /// </summary>
    public string GetOrCreateInstallId()
    {
        var existing = GetValue("installId");
        if (!string.IsNullOrEmpty(existing)) return existing;

        var id = Guid.NewGuid().ToString();
        SetValue("installId", id);
        return id;
    }

    /// <summary>
    /// Returns the per-user encryption key for <see cref="ActiveUserEmail"/>, creating one
    /// if it doesn't exist. Returns null if no user is signed in — callers must treat a null
    /// return as "no key available" (skip encryption / error). We deliberately refuse to
    /// create a key scoped to an empty email, which would otherwise be shared across users.
    /// </summary>
    public virtual byte[]? GetOrCreateUserEncryptionKey()
    {
        var email = ActiveUserEmail;
        if (string.IsNullOrWhiteSpace(email)) return null;
        return GetOrCreateEncryptionKey(email);
    }

    /// <summary>
    /// Returns the 32-byte encryption key for the given user, creating one if it doesn't exist.
    /// On first call after upgrade, migrates the legacy device-wide key to the user's account.
    /// </summary>
    public byte[]? GetOrCreateEncryptionKey(string userEmail)
    {
        if (string.IsNullOrWhiteSpace(userEmail)) return null;
        var userKeyName = $"encryptionKey_{userEmail}";

        // 1. Check for existing per-user key
        var existing = GetValue(userKeyName);
        if (existing != null)
        {
            try { return Convert.FromBase64String(existing); }
            catch { /* corrupt — regenerate below */ }
        }

        // 2. Migrate legacy device-wide key if present
        var legacy = GetValue(LegacyDeviceKeyName);
        if (legacy != null)
        {
            SetValue(userKeyName, legacy);
            RemoveValue(LegacyDeviceKeyName);
            try { return Convert.FromBase64String(legacy); }
            catch { /* corrupt — regenerate below */ }
        }

        // 3. Generate new 32-byte AES-256 key
        var key = new byte[32];
        System.Security.Cryptography.RandomNumberGenerator.Fill(key);
        SetValue(userKeyName, Convert.ToBase64String(key));
        return key;
    }

    /// <summary>
    /// Removes auth tokens only. Encryption keys are preserved so pending uploads
    /// can still be retried after the next sign-in.
    /// </summary>
    public void ClearAuthTokens()
    {
        foreach (var key in AuthTokenKeys)
        {
            RemoveValue(key);
        }
    }

    /// <summary>
    /// Removes auth tokens AND the encryption key for the given user.
    /// Call only for explicit "purge local data" — not on regular sign-out.
    /// </summary>
    public void PurgeAllData(string userEmail)
    {
        ClearAuthTokens();
        RemoveValue($"encryptionKey_{userEmail}");
        RemoveValue(LegacyDeviceKeyName);
    }
}
