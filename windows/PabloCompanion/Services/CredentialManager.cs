using Windows.Security.Credentials;

namespace PabloCompanion.Services;

/// <summary>
/// Stores and retrieves auth tokens using Windows Credential Manager (PasswordVault).
/// Mirrors KeychainManager.swift on macOS.
/// </summary>
public sealed class CredentialManager
{
    private const string Resource = "PabloCompanion";

    private static readonly string[] TokenKeys =
    [
        "idToken", "refreshToken", "userEmail",
        "authServerURL", "firebaseAPIKey", "backendAPIURL", "tenantID"
    ];

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
    /// Removes all stored credentials. Used during sign-out.
    /// </summary>
    public void ClearAll()
    {
        foreach (var key in TokenKeys)
        {
            RemoveValue(key);
        }
    }
}
