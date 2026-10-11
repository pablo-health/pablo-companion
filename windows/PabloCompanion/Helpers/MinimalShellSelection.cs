using System.Globalization;
using PabloCompanion.Models;
using PabloCompanion.Services;

namespace PabloCompanion.Helpers;

/// <summary>Which action the appointment card offers.</summary>
public enum AppointmentAction
{
    Start,
    Starting,
    StopRecording,
}

/// <summary>What the middle of the minimal window shows.</summary>
public enum ShellCardKind
{
    /// <summary>An appointment, with the action from <see cref="MinimalShellSelection.Action"/>.</summary>
    Appointment,

    /// <summary>A live recording whose appointment isn't in today's list.</summary>
    UntrackedRecording,

    Loading,
    Error,
    NoUpcoming,
}

/// <summary>
/// What the main window says about the session this PC just ended, while its
/// audio uploads and its note is written. Never shown over a live recording or
/// a start in flight.
/// </summary>
public enum UploadStatusKind
{
    None,
    Uploading,
    DraftingNote,
}

public sealed record ShellCard(
    ShellCardKind Kind,
    Appointment? Appointment = null,
    AppointmentAction Action = AppointmentAction.Start);

/// <summary>
/// Card-selection rules for <c>MinimalShellView</c>, kept free of WinUI so they
/// stay pure and unit-tested. A port of <c>MinimalMainView+Selection.swift</c>;
/// keep the two in step.
/// </summary>
public static class MinimalShellSelection
{
    /// <summary>
    /// Which action the card offers. An appointment with no session and no active
    /// recording are BOTH <c>null</c>, and a bare <c>==</c> reads that as "this is
    /// the recording in flight" - offering to stop a session that was never
    /// started. The non-null check is the whole point.
    /// </summary>
    public static AppointmentAction Action(
        Appointment appointment,
        string? activeSessionId,
        string? startingAppointmentId = null)
    {
        if (appointment.SessionId is { } sessionId && sessionId == activeSessionId)
            return AppointmentAction.StopRecording;
        return appointment.Id == startingAppointmentId
            ? AppointmentAction.Starting
            : AppointmentAction.Start;
    }

    /// <summary>
    /// The appointment the card shows.
    ///
    /// A session being recorded pins the card regardless of its end time or
    /// status; otherwise, once the scheduled end passed, a still-running
    /// recording would lose its only End Session button. An appointment mid-start
    /// is pinned the same way: its <c>session_id</c> lands before the recording's
    /// session id is set, and the filter below would skip it.
    ///
    /// An appointment whose session opened here but whose recording didn't start
    /// (<paramref name="unrecordedAppointmentId"/>) stays on the card until its
    /// slot ends, offering Start again: it has a <c>session_id</c> too, and the
    /// filter below would read it as done. (Windows-only: the Mac card advances.)
    ///
    /// Otherwise an appointment that already has a session is done, so the card
    /// advances to the next one.
    /// </summary>
    public static Appointment? NextAppointment(
        IReadOnlyList<Appointment> appointments,
        DateTimeOffset now,
        string? activeSessionId = null,
        string? startingAppointmentId = null,
        string? unrecordedAppointmentId = null)
    {
        // The live recording outranks one mid-start: it holds the End Session button.
        if (activeSessionId is not null)
        {
            var recording = appointments.FirstOrDefault(a => a.SessionId == activeSessionId);
            if (recording is not null) return recording;
        }

        if (startingAppointmentId is not null)
        {
            var starting = appointments.FirstOrDefault(a => a.Id == startingAppointmentId);
            if (starting is not null) return starting;
        }

        if (unrecordedAppointmentId is not null)
        {
            var unrecorded = appointments.FirstOrDefault(a => a.Id == unrecordedAppointmentId);
            if (unrecorded is not null && ParseDate(unrecorded.EndAt) is { } unrecordedEnd && unrecordedEnd >= now)
                return unrecorded;
        }

        Appointment? best = null;
        DateTimeOffset bestStart = default;
        foreach (var appointment in appointments)
        {
            if (string.Equals(appointment.Status, "cancelled", StringComparison.OrdinalIgnoreCase)) continue;
            if (appointment.SessionId is not null) continue;
            if (ParseDate(appointment.StartAt) is not { } start) continue;
            if (ParseDate(appointment.EndAt) is not { } end || end < now) continue;
            if (best is null || start < bestStart)
            {
                best = appointment;
                bestStart = start;
            }
        }
        return best;
    }

    /// <summary>
    /// An appointment whose session is being recorded somewhere other than this
    /// PC. Shown as a note, never as the card, so a session left open elsewhere
    /// can't stand between the therapist and the next Start Session. Only while
    /// the slot is still current, so a session someone forgot to end doesn't
    /// linger all day. Without <c>session_status</c>, nothing is reported.
    ///
    /// A session this PC ended (<paramref name="endedHereSessionIds"/>) is never
    /// "elsewhere": the server keeps it in progress until its upload finalizes,
    /// which for a long session outlasts the next refresh.
    /// </summary>
    public static Appointment? InProgressElsewhere(
        IReadOnlyList<Appointment> appointments,
        DateTimeOffset now,
        string? activeSessionId = null,
        string? startingAppointmentId = null,
        string? unrecordedAppointmentId = null,
        IReadOnlyCollection<string>? endedHereSessionIds = null)
    {
        return appointments.FirstOrDefault(appointment =>
            appointment.ParsedSessionStatus() == SessionStatus.InProgress
            && appointment.SessionId is { } sessionId
            && sessionId != activeSessionId
            && endedHereSessionIds?.Contains(sessionId) != true
            && appointment.Id != startingAppointmentId
            && appointment.Id != unrecordedAppointmentId
            && ParseDate(appointment.EndAt) is { } end
            && end >= now);
    }

    /// <summary>
    /// Card priority: a recording in flight wins over every other state -
    /// including a failed refresh - because this window holds the only End
    /// Session button. Then loading, then error, then "nothing left today".
    /// </summary>
    public static ShellCard SelectCard(
        IReadOnlyList<Appointment> appointments,
        DateTimeOffset now,
        string? activeSessionId,
        string? startingAppointmentId,
        bool isLoading,
        bool hasError,
        string? unrecordedAppointmentId = null)
    {
        if (NextAppointment(appointments, now, activeSessionId, startingAppointmentId, unrecordedAppointmentId) is { } appointment)
        {
            return new ShellCard(
                ShellCardKind.Appointment,
                appointment,
                Action(appointment, activeSessionId, startingAppointmentId));
        }
        if (activeSessionId is not null) return new ShellCard(ShellCardKind.UntrackedRecording);
        if (isLoading && appointments.Count == 0) return new ShellCard(ShellCardKind.Loading);
        if (hasError && appointments.Count == 0) return new ShellCard(ShellCardKind.Error);
        return new ShellCard(ShellCardKind.NoUpcoming);
    }

    /// <summary>
    /// The card's timing label. The appointment being recorded here, or being
    /// started, is "IN SESSION" whatever the clock says (paused included): a
    /// session started before its slot otherwise read "NEXT UP" above its own
    /// live recording. Everything else is labelled from the clock.
    /// </summary>
    public static string TimingLabel(
        Appointment appointment,
        DateTimeOffset now,
        string? activeSessionId,
        string? startingAppointmentId = null)
        => TimingLabel(appointment, now, Action(appointment, activeSessionId, startingAppointmentId));

    /// <summary>The timing label for the action the card already picked (see <see cref="Action"/>).</summary>
    public static string TimingLabel(
        Appointment appointment,
        DateTimeOffset now,
        AppointmentAction action = AppointmentAction.Start)
    {
        if (action is AppointmentAction.StopRecording or AppointmentAction.Starting) return "IN SESSION";
        if (ParseDate(appointment.StartAt) is not { } start) return "UPCOMING";
        if (ParseDate(appointment.EndAt) is { } end && end < now) return "RUNNING OVER";
        return start <= now ? "IN PROGRESS" : "NEXT UP";
    }

    /// <summary>
    /// What to say about the session this PC last ended. Only its first upload
    /// attempt reads as uploading: once an attempt failed, the upload backlog note
    /// owns it (with its retry), so the two never say the same thing. In the
    /// moment between End Session and the upload being queued
    /// (<paramref name="ending"/>), it is uploading too. Nothing while a recording
    /// is live or a start is in flight: the card belongs to that session.
    /// </summary>
    public static UploadStatusKind UploadStatus(SessionUploadPhase phase, bool ending, bool recordingOrStarting)
    {
        if (recordingOrStarting) return UploadStatusKind.None;
        return phase switch
        {
            SessionUploadPhase.Uploading => UploadStatusKind.Uploading,
            SessionUploadPhase.AwaitingNote => UploadStatusKind.DraftingNote,
            SessionUploadPhase.None when ending => UploadStatusKind.Uploading,
            _ => UploadStatusKind.None,
        };
    }

    public static string? UploadStatusTitle(UploadStatusKind kind) => kind switch
    {
        UploadStatusKind.Uploading => "Uploading your session...",
        UploadStatusKind.DraftingNote => "Drafting your note...",
        _ => null,
    };

    public static string? UploadStatusSubtitle(UploadStatusKind kind) => kind switch
    {
        UploadStatusKind.Uploading => "You can close Pablo once the upload finishes.",
        UploadStatusKind.DraftingNote => "Your note will be ready in the web dashboard.",
        _ => null,
    };

    /// <summary>Read from the capture's real state, so the card never says "Recording" once capture stopped.</summary>
    public static string CaptureStateLabel(RecordingUIState state) => state switch
    {
        RecordingUIState.Recording => "Recording",
        RecordingUIState.Paused => "Paused",
        _ => "Not recording",
    };

    /// <summary>Start time as a local short time, e.g. "3:00 PM".</summary>
    public static string FormattedTime(string value, TimeZoneInfo? zone = null)
    {
        if (ParseDate(value) is not { } date) return "Time unavailable";
        var local = TimeZoneInfo.ConvertTime(date, zone ?? TimeZoneInfo.Local);
        return local.ToString("t", CultureInfo.CurrentCulture);
    }

    /// <summary>ISO 8601 with an offset; a value with none is read as UTC.</summary>
    public static DateTimeOffset? ParseDate(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        return DateTimeOffset.TryParse(
            value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var date)
            ? date
            : null;
    }
}
