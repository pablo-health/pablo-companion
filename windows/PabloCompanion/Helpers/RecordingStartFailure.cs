using System.Runtime.InteropServices;
using AudioCapture.Models;
using PabloCompanion.Services;

namespace PabloCompanion.Helpers;

/// <summary>
/// What the therapist is told when a capture doesn't start, and whether the fix
/// is the Windows microphone privacy setting (which the window links to).
/// </summary>
/// <param name="Message">The line shown in the main window.</param>
/// <param name="IsMicrophonePermission">True when Windows refused the microphone.</param>
public sealed record RecordingStartFailure(string Message, bool IsMicrophonePermission)
{
    public const string EncryptionUnavailableMessage =
        "Recording didn't start because Pablo couldn't encrypt the audio on this PC.";

    public const string MicrophonePermissionMessage =
        "Pablo needs your microphone. Turn on microphone access in Settings > Privacy & security > Microphone, then start the session again.";

    public const string DeviceUnavailableMessage =
        "Audio device not available. Check your microphone connection.";

    /// <summary>Opens Settings > Privacy & security > Microphone.</summary>
    public const string MicrophoneSettingsUri = "ms-settings:privacy-microphone";

    private const int EAccessDenied = unchecked((int)0x80070005);

    public static RecordingStartFailure Describe(Exception error)
    {
        if (error is RecordingEncryptionUnavailableException)
            return new(EncryptionUnavailableMessage, false);
        if (IsAccessDenied(error))
            return new(MicrophonePermissionMessage, true);
        if (error is CaptureException { ErrorKind: CaptureErrorKind.DeviceNotAvailable })
            return new(DeviceUnavailableMessage, false);
        return new($"Recording failed: {error.Message}", false);
    }

    /// <summary>
    /// Windows refuses a microphone it isn't allowed to use with E_ACCESSDENIED,
    /// which .NET surfaces as <see cref="UnauthorizedAccessException"/>. The
    /// capture's configure step re-wraps failures keeping only the message, so
    /// the HRESULT text is checked too.
    /// </summary>
    internal static bool IsAccessDenied(Exception error)
    {
        for (Exception? e = error; e is not null; e = e.InnerException)
        {
            if (e is UnauthorizedAccessException) return true;
            if (e is CaptureException { ErrorKind: CaptureErrorKind.PermissionDenied }) return true;
            if (e.HResult == EAccessDenied) return true;
            if (e is COMException com && com.ErrorCode == EAccessDenied) return true;
            if (e.Message.Contains("E_ACCESSDENIED", StringComparison.OrdinalIgnoreCase)
                || e.Message.Contains("0x80070005", StringComparison.OrdinalIgnoreCase))
                return true;
            if (e is AggregateException aggregate && aggregate.InnerExceptions.Any(IsAccessDenied)) return true;
        }
        return false;
    }
}
