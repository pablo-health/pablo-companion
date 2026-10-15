namespace PabloCompanion.Services;

/// <summary>
/// On-disk locations the app owns, all under <c>%LOCALAPPDATA%\PabloCompanion\</c>.
///
/// Stores and services that take a directory as a constructor parameter (so
/// tests can point them at a temp directory) default to these values. The
/// Windows counterpart of macOS <c>AppPaths</c>.
/// </summary>
public static class AppPaths
{
    /// <summary><c>%LOCALAPPDATA%\PabloCompanion\</c></summary>
    public static string Root { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "PabloCompanion");

    /// <summary>Session audio: one subdirectory per session ID.</summary>
    public static string RecordingsRoot { get; } = Path.Combine(Root, "Recordings");

    /// <summary>Session ID to local recording file paths.</summary>
    public static string SessionRecordingsFile { get; } = Path.Combine(Root, "SessionRecordings.json");

    /// <summary>Diagnostic log written by <c>App.Log</c>.</summary>
    public static string CrashLog { get; } = Path.Combine(Root, "crash.log");

    /// <summary>Marker recording that the first-use audio check was offered.</summary>
    public static string AudioCheckOfferedMarker { get; } = Path.Combine(Root, "audio-check-offered");
}
