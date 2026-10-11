namespace PabloCompanion.Models;

/// <summary>Which side of the connection is too old.</summary>
public enum UpdateRequiredKind
{
    /// <summary>The backend no longer supports this app version.</summary>
    ClientUpdate,

    /// <summary>This app needs a newer backend than the one it reached.</summary>
    ServerUpdate,
}

/// <summary>
/// Why the update-required screen is showing, with its copy. Mirrors
/// <c>UpdateRequiredView.Reason</c> on macOS: the same title, subtitle and
/// instruction for each case. There is no dismiss and no bypass.
/// </summary>
/// <param name="Kind">Client or server update.</param>
/// <param name="CurrentVersion">This app's version (client case) or the server's (server case).</param>
/// <param name="MinVersion">The minimum the other side requires, or null when unknown (a 426 that arrived before any health check).</param>
public sealed record UpdateRequiredReason(UpdateRequiredKind Kind, string CurrentVersion, string? MinVersion)
{
    public static UpdateRequiredReason ClientUpdate(string currentVersion, string? minVersion)
        => new(UpdateRequiredKind.ClientUpdate, currentVersion, minVersion);

    public static UpdateRequiredReason ServerUpdate(string serverVersion, string minRequired)
        => new(UpdateRequiredKind.ServerUpdate, serverVersion, minRequired);

    public string Title => Kind == UpdateRequiredKind.ClientUpdate
        ? "Update Required"
        : "Server Update Needed";

    public string Subtitle => Kind switch
    {
        UpdateRequiredKind.ClientUpdate when MinVersion is { Length: > 0 } min =>
            $"Your app (v{CurrentVersion}) is no longer supported. Version {min} or later is required.",
        UpdateRequiredKind.ClientUpdate =>
            $"Your app (v{CurrentVersion}) is no longer supported.",
        _ =>
            $"The server (v{CurrentVersion}) is not compatible with this app. Server v{MinVersion} or later is required.",
    };

    public string Instruction => Kind == UpdateRequiredKind.ClientUpdate
        ? "Please download the latest version to continue."
        : "Please contact your administrator.";

    /// <summary>Only the client case has something the user can do here: get the update.</summary>
    public bool ShowsUpdateButton => Kind == UpdateRequiredKind.ClientUpdate;
}
