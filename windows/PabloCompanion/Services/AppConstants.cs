namespace PabloCompanion.Services;

/// <summary>
/// Compile-time defaults the app uses when no saved override is present.
/// Self-hosters / developers can override via the "Connect to a different
/// server" affordance on the login screen, which writes to
/// <see cref="CredentialManager.AuthServerUrl"/>.
/// </summary>
public static class AppConstants
{
    public const string DefaultAuthServerUrl = "https://app.pablo.health";
}
