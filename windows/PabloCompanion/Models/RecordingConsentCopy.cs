using System.Globalization;
using PabloCompanion.Core;

namespace PabloCompanion.Models;

/// <summary>
/// The words the companion shows about a client's answer on AI-assisted notes.
/// Kept to what the web app says, so the clinician reads the same thing in
/// either app. The companion has no practice word for the people it serves, so
/// it says "client". Mirrors <c>RecordingConsentCopy.swift</c> on macOS.
/// </summary>
public static class RecordingConsentCopy
{
    public const string DeclinedTitle = "AI-assisted notes declined";
    public const string NotAskedTitle = "No consent for AI-assisted notes";

    /// <summary>
    /// Nothing on file, in person or over telehealth: the only way to record is to
    /// ask once recording starts, so the answer is on the recording. The script is
    /// shown then, not before; its first line says recording has started.
    /// </summary>
    public const string AskOnRecordingMessage = "You'll see what to read aloud once recording starts.";

    public const string StartAndAsk = "Start recording and ask";
    public const string DontRecord = "Don't record";
    public const string OpenChart = "Open chart";
    public const string Close = "Close";
    public const string AnsweredBy = "Answered by";
    public const string SaveFailed = "Could not save. Please try again.";

    /// <summary>The panel shown once recording has started, for a client asked on it.</summary>
    public const string AskingTitle = "Asking about AI-assisted notes";
    public const string AskingPrompt = "Recording has started. Read this aloud so the answer is on the recording.";
    public const string LocationLabel = "Where the client said they were";
    public const string RecordOnChart = "Record the client's answer on their chart.";

    /// <summary>After a decline on the recording: capture stopped and the audio deleted.</summary>
    public const string RecordingDeleted = "Recording stopped and deleted. Write this note yourself.";

    /// <summary>"Client agreed", "Guardian declined".</summary>
    public static string Answered(string decision, AiConsentGiver giver)
        => $"{giver.Word()} {(decision == AiConsentEntry.DeclinedDecision ? "declined" : "agreed")}";

    /// <summary>
    /// "This client declined AI-assisted notes on Oct 5, 2026." Leaves the date out
    /// when the server sent none.
    /// </summary>
    public static string Declined(string isoDay, CultureInfo? culture = null)
        => string.IsNullOrEmpty(isoDay)
            ? "This client declined AI-assisted notes."
            : $"This client declined AI-assisted notes on {RecordingConsent.DisplayDate(isoDay, culture)}.";
}
