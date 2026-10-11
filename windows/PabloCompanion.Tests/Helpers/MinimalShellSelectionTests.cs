using System.Text.Json;
using PabloCompanion.Helpers;
using PabloCompanion.Models;
using PabloCompanion.Services;

namespace PabloCompanion.Tests.Helpers;

/// <summary>
/// Ported from mac/PabloCompanionTests/MinimalMainViewTests.swift. Keep the two
/// suites in step: the rules are the same on both platforms.
/// </summary>
public class MinimalShellSelectionTests
{
    private static DateTimeOffset At(string iso) => DateTimeOffset.Parse(iso, System.Globalization.CultureInfo.InvariantCulture);

    private static Appointment MakeAppointment(
        string startAt,
        string endAt,
        string id = "appointment",
        string status = "scheduled",
        string? sessionId = null,
        string? sessionStatus = null) => new(
            Id: id,
            PatientId: "patient",
            Title: "Initial consultation",
            StartAt: startAt,
            EndAt: endAt,
            DurationMinutes: 50,
            Status: status,
            SessionId: sessionId,
            CreatedAt: "2026-09-03T14:00:00Z",
            SessionStatusRaw: sessionStatus);

    // --- NextAppointment ---

    [Fact]
    public void SelectsAppointmentStartingInFifteenMinutes()
    {
        var appointment = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z");
        var selected = MinimalShellSelection.NextAppointment([appointment], At("2026-09-03T14:45:00Z"));
        Assert.Equal(appointment.Id, selected?.Id);
    }

    [Fact]
    public void KeepsCurrentAppointmentVisibleUntilItEnds()
    {
        var appointment = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z");
        var selected = MinimalShellSelection.NextAppointment([appointment], At("2026-09-03T15:15:00Z"));
        Assert.Equal(appointment.Id, selected?.Id);
    }

    [Fact]
    public void IgnoresCancelledAppointments()
    {
        var cancelled = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z", status: "cancelled");
        var active = MakeAppointment("2026-09-03T16:00:00Z", "2026-09-03T16:50:00Z", id: "active");
        var selected = MinimalShellSelection.NextAppointment([cancelled, active], At("2026-09-03T14:45:00Z"));
        Assert.Equal("active", selected?.Id);
    }

    [Fact]
    public void IgnoresCancelledRegardlessOfCase()
    {
        var cancelled = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z", status: "Cancelled");
        Assert.Null(MinimalShellSelection.NextAppointment([cancelled], At("2026-09-03T14:45:00Z")));
    }

    [Fact]
    public void KeepsTheRecordingAppointmentAfterItsScheduledEnd()
    {
        // Regression: once the scheduled end passed, the end >= now filter dropped
        // the appointment while still recording, with no End Session button left.
        var recording = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z", sessionId: "session-1");
        var selected = MinimalShellSelection.NextAppointment(
            [recording], At("2026-09-03T15:51:00Z"), activeSessionId: "session-1");
        Assert.Equal(recording.Id, selected?.Id);
    }

    [Fact]
    public void HoldsAnAppointmentAtItsExactEndInstant()
    {
        var appointment = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z");
        var selected = MinimalShellSelection.NextAppointment([appointment], At("2026-09-03T15:50:00Z"));
        Assert.Equal(appointment.Id, selected?.Id);
    }

    [Fact]
    public void DropsAnAppointmentOneSecondAfterItsEnd()
    {
        var appointment = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z");
        Assert.Null(MinimalShellSelection.NextAppointment([appointment], At("2026-09-03T15:50:01Z")));
    }

    [Fact]
    public void KeepsTheRecordingAppointmentLongPastItsEnd()
    {
        var recording = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z", sessionId: "session-1");
        var upcoming = MakeAppointment("2026-09-03T18:00:00Z", "2026-09-03T18:50:00Z", id: "later");
        var selected = MinimalShellSelection.NextAppointment(
            [recording, upcoming], At("2026-09-03T17:30:00Z"), activeSessionId: "session-1");
        Assert.Equal(recording.Id, selected?.Id);
    }

    [Fact]
    public void KeepsTheRecordingAppointmentEvenIfCancelled()
    {
        var recording = MakeAppointment(
            "2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z", status: "cancelled", sessionId: "session-1");
        var selected = MinimalShellSelection.NextAppointment(
            [recording], At("2026-09-03T15:20:00Z"), activeSessionId: "session-1");
        Assert.Equal(recording.Id, selected?.Id);
    }

    [Fact]
    public void AdvancesPastAnEndedAppointmentWhenNothingIsRecording()
    {
        var ended = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z", sessionId: "session-1");
        var upcoming = MakeAppointment("2026-09-03T16:00:00Z", "2026-09-03T16:50:00Z", id: "later");
        var selected = MinimalShellSelection.NextAppointment([ended, upcoming], At("2026-09-03T15:51:00Z"));
        Assert.Equal("later", selected?.Id);
    }

    [Fact]
    public void AdvancesPastASessionEndedBeforeItsScheduledEnd()
    {
        var endedEarly = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z", sessionId: "session-1");
        var upcoming = MakeAppointment("2026-09-03T16:00:00Z", "2026-09-03T16:50:00Z", id: "later");
        var selected = MinimalShellSelection.NextAppointment([endedEarly, upcoming], At("2026-09-03T15:20:00Z"));
        Assert.Equal("later", selected?.Id);
    }

    [Fact]
    public void ShowsNothingWhenTheLastSessionEndedEarly()
    {
        var endedEarly = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z", sessionId: "session-1");
        Assert.Null(MinimalShellSelection.NextAppointment([endedEarly], At("2026-09-03T15:20:00Z")));
    }

    [Fact]
    public void SkipsAStartedSessionWhileAnotherIsRecording()
    {
        var earlier = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z", sessionId: "session-1");
        var recording = MakeAppointment(
            "2026-09-03T15:15:00Z", "2026-09-03T16:05:00Z", id: "recording", sessionId: "session-2");
        var selected = MinimalShellSelection.NextAppointment(
            [earlier, recording], At("2026-09-03T15:20:00Z"), activeSessionId: "session-2");
        Assert.Equal("recording", selected?.Id);
    }

    [Fact]
    public void PicksTheEarliestStartRegardlessOfListOrder()
    {
        var later = MakeAppointment("2026-09-03T17:00:00Z", "2026-09-03T17:50:00Z", id: "later");
        var sooner = MakeAppointment("2026-09-03T16:00:00Z", "2026-09-03T16:50:00Z", id: "sooner");
        var selected = MinimalShellSelection.NextAppointment([later, sooner], At("2026-09-03T15:00:00Z"));
        Assert.Equal("sooner", selected?.Id);
    }

    [Fact]
    public void PinsTheAppointmentBeingStarted()
    {
        // Starting refreshes the list (linking session_id) before the recording's
        // session id is set. Without the pin the card would skip to the next patient.
        var starting = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z", sessionId: "session-1");
        var upcoming = MakeAppointment("2026-09-03T16:00:00Z", "2026-09-03T16:50:00Z", id: "later");
        var selected = MinimalShellSelection.NextAppointment(
            [starting, upcoming], At("2026-09-03T14:58:00Z"),
            activeSessionId: null, startingAppointmentId: starting.Id);
        Assert.Equal(starting.Id, selected?.Id);
    }

    [Fact]
    public void KeepsTheRecordingCardWhileAnotherSessionIsStarting()
    {
        var starting = MakeAppointment("2026-09-03T15:45:00Z", "2026-09-03T16:35:00Z", id: "starting");
        var recording = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z", sessionId: "session-1");
        var selected = MinimalShellSelection.NextAppointment(
            [starting, recording], At("2026-09-03T15:40:00Z"),
            activeSessionId: "session-1", startingAppointmentId: "starting");
        Assert.Equal(recording.Id, selected?.Id);
    }

    // --- TimingLabel ---

    [Theory]
    [InlineData("2026-09-03T14:45:00Z", "NEXT UP")]
    [InlineData("2026-09-03T15:00:00Z", "IN PROGRESS")]
    [InlineData("2026-09-03T15:50:00Z", "IN PROGRESS")]
    [InlineData("2026-09-03T16:05:00Z", "RUNNING OVER")]
    public void LabelsTheTimingOfAnAppointment(string now, string expected)
    {
        var appointment = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z", sessionId: "session-1");
        Assert.Equal(expected, MinimalShellSelection.TimingLabel(appointment, At(now)));
    }

    /// <summary>
    /// Regression: a session started before its slot read "NEXT UP" above its own
    /// live recording. The appointment being recorded here, or being started, is
    /// "IN SESSION" whatever the clock says; every other appointment keeps the
    /// clock labels.
    /// </summary>
    [Theory]
    // Recording here (paused too: the active session id is kept while paused).
    [InlineData("2026-09-03T14:45:00Z", "session-1", null, "IN SESSION")]
    [InlineData("2026-09-03T15:10:00Z", "session-1", null, "IN SESSION")]
    [InlineData("2026-09-03T16:05:00Z", "session-1", null, "IN SESSION")]
    // Being started.
    [InlineData("2026-09-03T14:45:00Z", null, "appointment", "IN SESSION")]
    [InlineData("2026-09-03T15:10:00Z", null, "appointment", "IN SESSION")]
    [InlineData("2026-09-03T16:05:00Z", null, "appointment", "IN SESSION")]
    // Another session recording, or another appointment starting: the clock.
    [InlineData("2026-09-03T14:45:00Z", "session-2", null, "NEXT UP")]
    [InlineData("2026-09-03T15:10:00Z", "session-2", null, "IN PROGRESS")]
    [InlineData("2026-09-03T16:05:00Z", "session-2", null, "RUNNING OVER")]
    [InlineData("2026-09-03T14:45:00Z", null, "other", "NEXT UP")]
    [InlineData("2026-09-03T15:10:00Z", null, "other", "IN PROGRESS")]
    [InlineData("2026-09-03T16:05:00Z", null, "other", "RUNNING OVER")]
    // Nothing recording or starting: the clock.
    [InlineData("2026-09-03T14:45:00Z", null, null, "NEXT UP")]
    [InlineData("2026-09-03T15:10:00Z", null, null, "IN PROGRESS")]
    [InlineData("2026-09-03T16:05:00Z", null, null, "RUNNING OVER")]
    public void LabelsTheSessionBeingRecordedHereAsInSession(
        string now, string? activeSessionId, string? startingAppointmentId, string expected)
    {
        var appointment = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z", sessionId: "session-1");
        Assert.Equal(expected, MinimalShellSelection.TimingLabel(
            appointment, At(now), activeSessionId, startingAppointmentId));
    }

    [Fact]
    public void AnAppointmentWithNoSessionIsNeverInSessionBecauseNothingIsRecording()
    {
        // Both session ids null must not read as "this one is recording".
        var appointment = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z");
        Assert.Equal("NEXT UP", MinimalShellSelection.TimingLabel(
            appointment, At("2026-09-03T14:45:00Z"), activeSessionId: null));
    }

    [Theory]
    [InlineData(AppointmentAction.StopRecording, "IN SESSION")]
    [InlineData(AppointmentAction.Starting, "IN SESSION")]
    [InlineData(AppointmentAction.Start, "NEXT UP")]
    public void TheCardsActionDecidesInSession(AppointmentAction action, string expected)
    {
        var appointment = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z", sessionId: "session-1");
        Assert.Equal(expected, MinimalShellSelection.TimingLabel(appointment, At("2026-09-03T14:45:00Z"), action));
    }

    [Fact]
    public void AnInSessionAppointmentWithoutAStartTimeIsStillInSession()
    {
        var appointment = MakeAppointment("", "2026-09-03T15:50:00Z", sessionId: "session-1");
        Assert.Equal("IN SESSION", MinimalShellSelection.TimingLabel(
            appointment, At("2026-09-03T14:45:00Z"), activeSessionId: "session-1"));
        Assert.Equal("UPCOMING", MinimalShellSelection.TimingLabel(appointment, At("2026-09-03T14:45:00Z")));
    }

    // --- Action ---

    [Fact]
    public void OffersStartWhenNothingIsRecording()
    {
        // Regression: appointment.SessionId and the active session id are both null
        // on a fresh launch; a bare == read that as "recording in flight".
        var appointment = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z");
        Assert.Equal(AppointmentAction.Start, MinimalShellSelection.Action(appointment, activeSessionId: null));
    }

    [Fact]
    public void OffersStartWhileAnotherSessionIsRecording()
    {
        var appointment = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z");
        Assert.Equal(AppointmentAction.Start, MinimalShellSelection.Action(appointment, activeSessionId: "other-session"));
    }

    [Fact]
    public void OffersStopForTheSessionBeingRecorded()
    {
        var appointment = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z", sessionId: "session-1");
        Assert.Equal(AppointmentAction.StopRecording, MinimalShellSelection.Action(appointment, activeSessionId: "session-1"));
    }

    [Fact]
    public void OffersStartingWhileTheSessionIsBeingCreated()
    {
        var appointment = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z");
        Assert.Equal(
            AppointmentAction.Starting,
            MinimalShellSelection.Action(appointment, activeSessionId: null, startingAppointmentId: appointment.Id));
    }

    [Fact]
    public void OffersStopOnceTheStartingSessionIsRecording()
    {
        var appointment = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z", sessionId: "session-1");
        Assert.Equal(
            AppointmentAction.StopRecording,
            MinimalShellSelection.Action(appointment, activeSessionId: "session-1", startingAppointmentId: appointment.Id));
    }

    // --- SelectCard priority ---

    [Fact]
    public void ARecordingWithNoMatchingAppointmentStillShowsTheControls()
    {
        var card = MinimalShellSelection.SelectCard(
            [], At("2026-09-03T15:00:00Z"), activeSessionId: "session-1",
            startingAppointmentId: null, isLoading: true, hasError: true);
        Assert.Equal(ShellCardKind.UntrackedRecording, card.Kind);
    }

    [Fact]
    public void LoadingOutranksError()
    {
        var card = MinimalShellSelection.SelectCard(
            [], At("2026-09-03T15:00:00Z"), activeSessionId: null,
            startingAppointmentId: null, isLoading: true, hasError: true);
        Assert.Equal(ShellCardKind.Loading, card.Kind);
    }

    [Fact]
    public void ErrorOutranksNoUpcoming()
    {
        var card = MinimalShellSelection.SelectCard(
            [], At("2026-09-03T15:00:00Z"), activeSessionId: null,
            startingAppointmentId: null, isLoading: false, hasError: true);
        Assert.Equal(ShellCardKind.Error, card.Kind);
    }

    [Fact]
    public void NothingLeftTodayShowsNoUpcoming()
    {
        var ended = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z", sessionId: "session-1");
        var card = MinimalShellSelection.SelectCard(
            [ended], At("2026-09-03T16:00:00Z"), activeSessionId: null,
            startingAppointmentId: null, isLoading: false, hasError: false);
        Assert.Equal(ShellCardKind.NoUpcoming, card.Kind);
    }

    [Fact]
    public void TheCardCarriesTheAppointmentAndItsAction()
    {
        var recording = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z", sessionId: "session-1");
        var card = MinimalShellSelection.SelectCard(
            [recording], At("2026-09-03T15:10:00Z"), activeSessionId: "session-1",
            startingAppointmentId: null, isLoading: true, hasError: false);
        Assert.Equal(ShellCardKind.Appointment, card.Kind);
        Assert.Equal(recording.Id, card.Appointment?.Id);
        Assert.Equal(AppointmentAction.StopRecording, card.Action);
    }

    // --- Recording on another device (session_status) ---

    [Fact]
    public void ReportsASessionRecordingOnAnotherDevice()
    {
        var now = At("2026-09-03T15:20:00Z");
        var elsewhere = MakeAppointment(
            "2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z", sessionId: "session-1", sessionStatus: "in_progress");
        var upcoming = MakeAppointment("2026-09-03T16:00:00Z", "2026-09-03T16:50:00Z", id: "later");

        Assert.Equal(elsewhere.Id, MinimalShellSelection.InProgressElsewhere([elsewhere, upcoming], now)?.Id);
        // A note, not the card: the next Start Session stays reachable.
        Assert.Equal("later", MinimalShellSelection.NextAppointment([elsewhere, upcoming], now)?.Id);
    }

    [Fact]
    public void TheSessionRecordingHereIsNotElsewhere()
    {
        var now = At("2026-09-03T15:20:00Z");
        var recording = MakeAppointment(
            "2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z", sessionId: "session-1", sessionStatus: "in_progress");

        Assert.Null(MinimalShellSelection.InProgressElsewhere([recording], now, activeSessionId: "session-1"));
        Assert.Null(MinimalShellSelection.InProgressElsewhere([recording], now, startingAppointmentId: recording.Id));
    }

    /// <summary>
    /// Regression: right after End Session the server still reports the session
    /// in progress until its upload finalizes, and the card said "Recording on
    /// another device" about the session this PC had just ended.
    /// </summary>
    [Fact]
    public void ASessionEndedHereIsNotElsewhereWhileTheServerStillReportsItInProgress()
    {
        var now = At("2026-09-03T15:20:00Z");
        var endedHere = MakeAppointment(
            "2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z", sessionId: "session-1", sessionStatus: "in_progress");
        var later = MakeAppointment("2026-09-03T16:00:00Z", "2026-09-03T16:50:00Z", id: "later");
        string[] ended = ["session-1"];

        Assert.Null(MinimalShellSelection.InProgressElsewhere(
            [endedHere, later], now, endedHereSessionIds: ended));

        // Nor does it pin the card: the next appointment is offered.
        var card = MinimalShellSelection.SelectCard(
            [endedHere, later], now, activeSessionId: null, startingAppointmentId: null,
            isLoading: false, hasError: false);
        Assert.Equal("later", card.Appointment?.Id);
        Assert.Equal(AppointmentAction.Start, card.Action);
    }

    [Fact]
    public void AForeignSessionIsStillElsewhereWhenAnotherWasEndedHere()
    {
        var now = At("2026-09-03T15:20:00Z");
        var endedHere = MakeAppointment(
            "2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z", id: "mine", sessionId: "session-1", sessionStatus: "in_progress");
        var foreign = MakeAppointment(
            "2026-09-03T15:05:00Z", "2026-09-03T15:55:00Z", id: "foreign", sessionId: "session-9", sessionStatus: "in_progress");

        Assert.Equal("foreign", MinimalShellSelection.InProgressElsewhere(
            [endedHere, foreign], now, endedHereSessionIds: ["session-1"])?.Id);
        Assert.Equal("mine", MinimalShellSelection.InProgressElsewhere(
            [endedHere, foreign], now, endedHereSessionIds: [])?.Id);
    }

    // --- Upload status after End Session ---

    [Theory]
    [InlineData(SessionUploadPhase.Uploading, false, false, UploadStatusKind.Uploading)]
    [InlineData(SessionUploadPhase.AwaitingNote, false, false, UploadStatusKind.DraftingNote)]
    // A failed attempt belongs to the backlog note, with its retry.
    [InlineData(SessionUploadPhase.WaitingToRetry, false, false, UploadStatusKind.None)]
    [InlineData(SessionUploadPhase.WaitingToRetry, true, false, UploadStatusKind.None)]
    // Note written, audio deleted: back to the next appointment.
    [InlineData(SessionUploadPhase.None, false, false, UploadStatusKind.None)]
    // Between End Session and the upload being queued.
    [InlineData(SessionUploadPhase.None, true, false, UploadStatusKind.Uploading)]
    // A live recording or a start in flight owns the card.
    [InlineData(SessionUploadPhase.Uploading, false, true, UploadStatusKind.None)]
    [InlineData(SessionUploadPhase.AwaitingNote, false, true, UploadStatusKind.None)]
    [InlineData(SessionUploadPhase.None, true, true, UploadStatusKind.None)]
    public void SaysWhatTheEndedSessionsUploadIsDoing(
        SessionUploadPhase phase, bool ending, bool recordingOrStarting, UploadStatusKind expected)
    {
        Assert.Equal(expected, MinimalShellSelection.UploadStatus(phase, ending, recordingOrStarting));
    }

    [Fact]
    public void UploadStatusCopy()
    {
        Assert.Equal("Uploading your session...", MinimalShellSelection.UploadStatusTitle(UploadStatusKind.Uploading));
        Assert.Equal("You can close Pablo once the upload finishes.",
            MinimalShellSelection.UploadStatusSubtitle(UploadStatusKind.Uploading));
        Assert.Equal("Drafting your note...", MinimalShellSelection.UploadStatusTitle(UploadStatusKind.DraftingNote));
        Assert.Equal("Your note will be ready in the web dashboard.",
            MinimalShellSelection.UploadStatusSubtitle(UploadStatusKind.DraftingNote));
        Assert.Null(MinimalShellSelection.UploadStatusTitle(UploadStatusKind.None));
        Assert.Null(MinimalShellSelection.UploadStatusSubtitle(UploadStatusKind.None));
    }

    [Fact]
    public void AnEndedSessionIsNotElsewhere()
    {
        var ended = MakeAppointment(
            "2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z", sessionId: "session-1", sessionStatus: "recording_complete");
        Assert.Null(MinimalShellSelection.InProgressElsewhere([ended], At("2026-09-03T15:20:00Z")));
    }

    [Fact]
    public void ElsewhereIsReportedThroughTheExactEndInstantOnly()
    {
        var elsewhere = MakeAppointment(
            "2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z", sessionId: "session-1", sessionStatus: "in_progress");
        Assert.NotNull(MinimalShellSelection.InProgressElsewhere([elsewhere], At("2026-09-03T15:50:00Z")));
        Assert.Null(MinimalShellSelection.InProgressElsewhere([elsewhere], At("2026-09-03T15:50:01Z")));
    }

    [Fact]
    public void AForgottenSessionStopsBeingReportedAfterItsSlot()
    {
        var forgotten = MakeAppointment(
            "2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z", sessionId: "session-1", sessionStatus: "in_progress");
        Assert.Null(MinimalShellSelection.InProgressElsewhere([forgotten], At("2026-09-03T17:00:00Z")));
    }

    [Fact]
    public void WithoutSessionStatusNothingIsReportedElsewhere()
    {
        // Older backends: fall back to the session_id rule, report nothing.
        var now = At("2026-09-03T15:20:00Z");
        var started = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z", sessionId: "session-1");

        Assert.Null(MinimalShellSelection.InProgressElsewhere([started], now));
        Assert.Null(MinimalShellSelection.NextAppointment([started], now));
    }

    // --- A session whose recording didn't start (Windows-only) ---

    [Fact]
    public void AnUnrecordedAppointmentStaysOnTheCardOfferingStart()
    {
        var unrecorded = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z",
            id: "unrecorded", sessionId: "session-1", sessionStatus: "scheduled");
        var later = MakeAppointment("2026-09-03T16:00:00Z", "2026-09-03T16:50:00Z", id: "later");
        var now = At("2026-09-03T15:10:00Z");

        var card = MinimalShellSelection.SelectCard(
            [unrecorded, later], now, activeSessionId: null, startingAppointmentId: null,
            isLoading: false, hasError: false, unrecordedAppointmentId: "unrecorded");

        Assert.Equal("unrecorded", card.Appointment?.Id);
        Assert.Equal(AppointmentAction.Start, card.Action);

        // Without the pin it reads as done and the card advances.
        Assert.Equal("later", MinimalShellSelection.NextAppointment([unrecorded, later], now)?.Id);
    }

    [Fact]
    public void AnUnrecordedAppointmentIsNotRecordingOnAnotherDevice()
    {
        var unrecorded = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z",
            id: "unrecorded", sessionId: "session-1", sessionStatus: "in_progress");
        var now = At("2026-09-03T15:10:00Z");

        Assert.NotNull(MinimalShellSelection.InProgressElsewhere([unrecorded], now));
        Assert.Null(MinimalShellSelection.InProgressElsewhere([unrecorded], now, unrecordedAppointmentId: "unrecorded"));
    }

    [Fact]
    public void AnUnrecordedAppointmentLetsGoOfTheCardOnceItsSlotEnds()
    {
        var unrecorded = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z",
            id: "unrecorded", sessionId: "session-1");
        var later = MakeAppointment("2026-09-03T16:00:00Z", "2026-09-03T16:50:00Z", id: "later");

        var selected = MinimalShellSelection.NextAppointment(
            [unrecorded, later], At("2026-09-03T15:55:00Z"), unrecordedAppointmentId: "unrecorded");

        Assert.Equal("later", selected?.Id);
    }

    [Fact]
    public void ALiveRecordingAndAStartInFlightOutrankAnUnrecordedAppointment()
    {
        var unrecorded = MakeAppointment("2026-09-03T15:00:00Z", "2026-09-03T15:50:00Z",
            id: "unrecorded", sessionId: "session-1");
        var recording = MakeAppointment("2026-09-03T14:00:00Z", "2026-09-03T14:50:00Z",
            id: "recording", sessionId: "session-2");
        var starting = MakeAppointment("2026-09-03T16:00:00Z", "2026-09-03T16:50:00Z", id: "starting");
        var now = At("2026-09-03T15:10:00Z");

        Assert.Equal("recording", MinimalShellSelection.NextAppointment(
            [unrecorded, recording, starting], now, "session-2", "starting", "unrecorded")?.Id);
        Assert.Equal("starting", MinimalShellSelection.NextAppointment(
            [unrecorded, recording, starting], now, null, "starting", "unrecorded")?.Id);
    }

    // --- Decoding session_status ---

    private static Appointment Decode(string sessionStatusJson)
    {
        var json = "{\"id\":\"a\",\"patient_id\":\"p\",\"title\":\"t\",\"start_at\":\"2026-09-03T15:00:00Z\","
            + "\"end_at\":\"2026-09-03T15:50:00Z\",\"duration_minutes\":50,\"status\":\"confirmed\","
            + "\"session_id\":\"s\",\"created_at\":\"2026-09-03T14:00:00Z\"" + sessionStatusJson + "}";
        return JsonSerializer.Deserialize<Appointment>(json)!;
    }

    [Fact]
    public void DecodesSessionStatusWhenPresent()
    {
        var appointment = Decode(",\"session_status\":\"pending_review\"");
        Assert.Equal(SessionStatus.PendingReview, appointment.ParsedSessionStatus());
    }

    [Fact]
    public void DecodesWithoutSessionStatusFromAnOlderBackend()
    {
        var appointment = Decode("");
        Assert.Null(appointment.SessionStatusRaw);
        Assert.Null(appointment.ParsedSessionStatus());
    }

    [Fact]
    public void AnUnknownSessionStatusDoesNotFailTheList()
    {
        var json = "{\"data\":[{\"id\":\"a\",\"patient_id\":\"p\",\"title\":\"t\","
            + "\"start_at\":\"2026-09-03T15:00:00Z\",\"end_at\":\"2026-09-03T15:50:00Z\","
            + "\"duration_minutes\":50,\"status\":\"confirmed\",\"session_id\":\"s\","
            + "\"session_status\":\"some_future_status\"},"
            + "{\"id\":\"b\",\"patient_id\":\"p\",\"title\":\"t\","
            + "\"start_at\":\"2026-09-03T16:00:00Z\",\"end_at\":\"2026-09-03T16:50:00Z\","
            + "\"duration_minutes\":50,\"status\":\"confirmed\",\"session_status\":\"in_progress\"}],"
            + "\"total\":2}";

        var list = JsonSerializer.Deserialize<AppointmentListResponse>(json)!;

        Assert.Equal(2, list.Data.Length);
        Assert.Equal("some_future_status", list.Data[0].SessionStatusRaw);
        Assert.Null(list.Data[0].ParsedSessionStatus());
        Assert.Equal(SessionStatus.InProgress, list.Data[1].ParsedSessionStatus());
    }
}
