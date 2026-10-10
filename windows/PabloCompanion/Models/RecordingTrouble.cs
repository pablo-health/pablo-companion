namespace PabloCompanion.Models;

/// <summary>What is wrong with the capture of an open session.</summary>
public enum RecordingTroubleKind
{
    /// <summary>Capture is running but the mic sidecar has stopped growing (the watchdog).</summary>
    Stalled,

    /// <summary>Capture has stopped while the session is still open.</summary>
    Stopped,
}

/// <summary>
/// Something wrong with the capture of an open session that the therapist has to
/// see: either no audio is arriving, or capture has stopped while the session is
/// still open. Either way the session's audio is being lost. A port of
/// <c>RecordingViewModel+Trouble.swift</c>; keep the two in step.
/// </summary>
/// <param name="Kind">Stalled or stopped.</param>
/// <param name="Message">The line the session card shows.</param>
public sealed record RecordingTrouble(RecordingTroubleKind Kind, string Message)
{
    public const string StalledMessage = "No new audio has been recorded in the last minute.";

    public const string MicDisconnectedMessage = "Recording stopped because the microphone was disconnected.";

    /// <summary>A capture that ended on its own for a reason the capture didn't name.</summary>
    public const string CaptureFailedMessage = "Recording stopped unexpectedly.";

    public static RecordingTrouble Stalled { get; } = new(RecordingTroubleKind.Stalled, StalledMessage);

    public static RecordingTrouble Stopped(string reason) => new(RecordingTroubleKind.Stopped, reason);

    /// <summary>
    /// What the session card has to say about capture, or null when recording is
    /// fine or no session is open.
    ///
    /// "Stopped" needs a reason, not just an idle state: the state is also idle
    /// for the moment between a session opening and capture starting, and the
    /// card must not call that a failure. Every way capture stops on its own
    /// leaves one: a mic disconnect sets <paramref name="micDisconnected"/>, and a
    /// failed restart or a capture failure sets <paramref name="persistentError"/>.
    /// </summary>
    public static RecordingTrouble? Evaluate(
        string? activeSessionId,
        RecordingUIState state,
        bool stalled,
        bool micDisconnected,
        string? persistentError)
    {
        if (activeSessionId is null) return null;
        return state switch
        {
            RecordingUIState.Idle when micDisconnected => Stopped(MicDisconnectedMessage),
            RecordingUIState.Idle => persistentError is { } reason ? Stopped(reason) : null,
            RecordingUIState.Recording => stalled ? Stalled : null,
            _ => null,
        };
    }
}
