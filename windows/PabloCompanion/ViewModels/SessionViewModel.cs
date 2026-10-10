using System.Net.Http;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Xaml;
using PabloCompanion.Core;
using PabloCompanion.Helpers;
using PabloCompanion.Services;
using PabloCompanion.Models;

namespace PabloCompanion.ViewModels;

/// <summary>
/// Manages session lifecycle, today's sessions, and session history.
/// Singleton — shared between DayPage and SessionHistoryPage.
/// Mirrors SessionViewModel.swift on macOS.
/// </summary>
public partial class SessionViewModel : ObservableObject
{
    private readonly APIClient _apiClient;
    private readonly VideoLaunchService _videoLaunch;
    private readonly RecordingViewModel _recordingVm;
    private readonly TranscriptionViewModel _transcriptionVm;
    private DispatcherTimer? _pollingTimer;
    private DispatcherTimer? _appointmentRefreshTimer;

    /// <summary>How often the minimal window re-reads today's appointments while signed in.</summary>
    public static readonly TimeSpan AppointmentRefreshInterval = TimeSpan.FromSeconds(60);

    // --- Today's appointments ---

    [ObservableProperty]
    public partial Appointment[] TodayAppointments { get; set; } = [];

    /// <summary>True while today's appointments are being fetched.</summary>
    [ObservableProperty]
    public partial bool IsLoadingAppointments { get; set; }

    /// <summary>
    /// Set when the last appointments fetch failed. Kept apart from
    /// <see cref="ErrorMessage"/>, which session start/end also write, so the
    /// card's "couldn't load" state means exactly that.
    /// </summary>
    [ObservableProperty]
    public partial string? AppointmentsErrorMessage { get; set; }

    /// <summary>
    /// Appointment whose session is being created/started but isn't recording
    /// yet. Pins the card (see <c>MinimalShellSelection.NextAppointment</c>) and
    /// doubles as the in-flight guard: a second Start while this is set is a no-op.
    /// </summary>
    [ObservableProperty]
    public partial string? StartingAppointmentId { get; set; }

    // --- Today's sessions ---

    [ObservableProperty]
    public partial Session[] TodaySessions { get; set; } = [];

    [ObservableProperty]
    public partial bool IsLoading { get; set; }

    [ObservableProperty]
    public partial string? ErrorMessage { get; set; }

    /// <summary>
    /// Set when a 403 indicates the subscription has lapsed.
    /// MainWindow observes this to trigger a subscription status refresh.
    /// </summary>
    [ObservableProperty]
    public partial bool SubscriptionBlocked { get; set; }

    [ObservableProperty]
    public partial Session? ActiveSession { get; set; }

    // --- Session history ---

    [ObservableProperty]
    public partial Session[] Sessions { get; set; } = [];

    [ObservableProperty]
    public partial uint TotalSessions { get; set; }

    [ObservableProperty]
    public partial bool HasMoreSessions { get; set; }

    [ObservableProperty]
    public partial bool IsLoadingHistory { get; set; }

    [ObservableProperty]
    public partial string? HistoryErrorMessage { get; set; }

    [ObservableProperty]
    public partial string? StatusFilter { get; set; }

    private uint _historyPage = 1;
    private const uint HistoryPageSize = 20;

    private readonly ISessionRecorder _recorder;

    public SessionViewModel(APIClient apiClient, VideoLaunchService videoLaunch,
        RecordingViewModel recordingVm, TranscriptionViewModel transcriptionVm,
        ISessionRecorder? recorder = null)
    {
        _apiClient = apiClient;
        _videoLaunch = videoLaunch;
        _recordingVm = recordingVm;
        _transcriptionVm = transcriptionVm;
        _recorder = recorder ?? new RecordingViewModelRecorder(recordingVm);
    }

    /// <summary>The recorder session starts arm; shared with the consent flow.</summary>
    internal ISessionRecorder Recorder => _recorder;

    /// <summary>
    /// A 403 that is about the subscription, not about the client's answer on
    /// AI-assisted notes (those carry their own codes and their own prompts).
    /// </summary>
    private static bool IsSubscriptionRefusal(PabloException ex)
        => ex.StatusCode == 403
            && ex.ErrorCode is not (RecordingConsent.ConsentNeededErrorCode or RecordingConsent.DeclinedErrorCode);

    /// <summary>
    /// Clears all session data. Called on sign-out to prevent PHI leakage.
    /// </summary>
    public void ClearAllData()
    {
        StopPolling();
        StopAppointmentRefresh();
        TodayAppointments = [];
        AppointmentsErrorMessage = null;
        StartingAppointmentId = null;
        TodaySessions = [];
        Sessions = [];
        ActiveSession = null;
        TotalSessions = 0;
        HasMoreSessions = false;
        StatusFilter = null;
        ErrorMessage = null;
        HistoryErrorMessage = null;
    }

    // --- Today (appointments) ---

    [RelayCommand]
    public async Task LoadTodayAppointmentsAsync()
    {
        IsLoading = true;
        IsLoadingAppointments = true;
        ErrorMessage = null;

        try
        {
            TodayAppointments = await _apiClient.FetchTodayAppointmentsAsync();
            AppointmentsErrorMessage = null;
        }
        catch (PabloException)
        {
            ErrorMessage = "Failed to load today's appointments.";
            AppointmentsErrorMessage = ErrorMessage;
        }
        catch (HttpRequestException)
        {
            ErrorMessage = "Failed to load appointments. Check your connection.";
            AppointmentsErrorMessage = ErrorMessage;
        }
        catch (Exception ex)
        {
            // Timeouts, malformed bodies: this runs from a timer, so nothing may
            // escape. Log the type only; a response body could carry PHI.
            System.Diagnostics.Debug.WriteLine($"LoadTodayAppointmentsAsync failed: {ex.GetType().Name}");
            ErrorMessage = "Failed to load appointments. Check your connection.";
            AppointmentsErrorMessage = ErrorMessage;
        }
        finally
        {
            IsLoading = false;
            IsLoadingAppointments = false;
        }
    }

    /// <summary>
    /// Start Session from the minimal window's card (or a confirmed handoff):
    /// create the session for the appointment, mark it in progress, arm the mic
    /// and open the video call. Guarded so a double-click (or a handoff landing
    /// while one start is in flight or a recording is live) creates exactly one
    /// session. The outcome says whether this call did the start
    /// (<see cref="AppointmentStartOutcome.Ran"/>) and how it ended.
    ///
    /// <paramref name="askingConsentOnRecording"/>: the clinician asks about
    /// AI-assisted notes once recording starts; the start tells the server so.
    /// A start the server refuses over the client's answer comes back as
    /// <see cref="AppointmentStartKind.Declined"/> or
    /// <see cref="AppointmentStartKind.ConsentNeeded"/>, never a generic error,
    /// and nothing was created or armed.
    ///
    /// Capture is awaited here (not fired and forgotten as in
    /// <see cref="StartSessionAsync"/>) so the caller knows whether the session is
    /// recording before it shows anything that says it is.
    /// </summary>
    public async Task<AppointmentStartOutcome> StartAppointmentSessionAsync(
        string appointmentId, bool askingConsentOnRecording = false)
    {
        if (StartingAppointmentId is not null) return AppointmentStartOutcome.Busy;
        if (_recordingVm.State != RecordingUIState.Idle || _recorder.ActiveSessionId is not null)
            return AppointmentStartOutcome.Busy;

        StartingAppointmentId = appointmentId;
        try
        {
            var created = await CreateSessionFromAppointmentAsync(appointmentId, askingConsentOnRecording);
            if (created.Kind != AppointmentStartKind.Started || created.SessionId is not { } sessionId)
                return created;

            var session = await MarkInProgressAndLaunchAsync(sessionId);
            if (session is null) return new AppointmentStartOutcome(AppointmentStartKind.Failed, sessionId);

            var recording = await _recorder.StartForSessionAsync(sessionId);
            _ = LoadTodaySessionsAsync();
            return new AppointmentStartOutcome(AppointmentStartKind.Started, sessionId, Recording: recording);
        }
        finally
        {
            StartingAppointmentId = null;
            // Pick up the session link and its in-progress status.
            await LoadTodayAppointmentsAsync();
        }
    }

    /// <summary>
    /// Returns a started session to "scheduled", the state of a session whose
    /// note is written by hand (the web starts one without recording). Called
    /// after a client declines AI-assisted notes on the recording and the
    /// recording is discarded, so the session never waits for audio.
    /// </summary>
    public async Task<bool> ReturnToHandWrittenAsync(string sessionId)
    {
        try
        {
            await _apiClient.UpdateSessionStatusAsync(sessionId, SessionStatus.Scheduled);
            if (ActiveSession?.Id == sessionId) ActiveSession = null;
            return true;
        }
        catch (Exception ex) when (ex is PabloException or HttpRequestException or InvalidOperationException)
        {
            App.LogException("SessionViewModel.ReturnToHandWritten", ex);
            ErrorMessage = "Failed to return the session to a hand-written note.";
            return false;
        }
    }

    /// <summary>
    /// Creates the backend session for an appointment and maps the server's
    /// refusals over AI-assisted notes onto their own outcomes.
    /// </summary>
    private async Task<AppointmentStartOutcome> CreateSessionFromAppointmentAsync(
        string appointmentId, bool askingConsentOnRecording)
    {
        try
        {
            var session = await _apiClient.StartSessionFromAppointmentAsync(appointmentId, askingConsentOnRecording);
            return new AppointmentStartOutcome(AppointmentStartKind.Started, session.Id);
        }
        catch (PabloException ex) when (ex.StatusCode == 403 && ex.ErrorCode == RecordingConsent.DeclinedErrorCode)
        {
            return new AppointmentStartOutcome(AppointmentStartKind.Declined,
                DeclinedOn: ex.ErrorDetails.GetValueOrDefault("declined_on") ?? "");
        }
        catch (PabloException ex) when (ex.StatusCode == 403 && ex.ErrorCode == RecordingConsent.ConsentNeededErrorCode)
        {
            return new AppointmentStartOutcome(AppointmentStartKind.ConsentNeeded);
        }
        catch (PabloException ex) when (IsSubscriptionRefusal(ex))
        {
            SubscriptionBlocked = true;
            ErrorMessage = "Subscription required to start sessions.";
            return new AppointmentStartOutcome(AppointmentStartKind.Failed);
        }
        catch (Exception ex) when (ex is PabloException or HttpRequestException or InvalidOperationException)
        {
            ErrorMessage = "Failed to start session from appointment.";
            return new AppointmentStartOutcome(AppointmentStartKind.Failed);
        }
    }

    /// <summary>
    /// End Session from the minimal window: stop, mark complete, upload (all in
    /// <see cref="EndSessionAsync"/>), then refresh the card so it advances.
    /// </summary>
    public async Task EndSessionAndRefreshAsync(string sessionId)
    {
        await EndSessionAsync(sessionId);
        await LoadTodayAppointmentsAsync();
    }

    [RelayCommand]
    public async Task<Session?> StartSessionFromAppointmentAsync(string appointmentId)
    {
        try
        {
            var session = await _apiClient.StartSessionFromAppointmentAsync(appointmentId);
            await LoadTodayAppointmentsAsync();
            return session;
        }
        catch (PabloException ex) when (IsSubscriptionRefusal(ex))
        {
            SubscriptionBlocked = true;
            ErrorMessage = "Subscription required to start sessions.";
            return null;
        }
        catch (PabloException)
        {
            ErrorMessage = "Failed to start session from appointment.";
            return null;
        }
        catch (HttpRequestException)
        {
            ErrorMessage = "Failed to start session from appointment.";
            return null;
        }
    }

    // --- Today (sessions, legacy) ---

    [RelayCommand]
    public async Task LoadTodaySessionsAsync()
    {
        IsLoading = true;
        ErrorMessage = null;

        try
        {
            var timezone = TimeZoneInfo.TryConvertWindowsIdToIanaId(TimeZoneInfo.Local.Id, out var iana)
                ? iana
                : TimeZoneInfo.Local.Id;
            var sessions = await _apiClient.FetchTodaySessionsAsync(timezone);
            TodaySessions = sessions;

            ActiveSession = sessions.FirstOrDefault(s =>
                s.Status == SessionStatus.InProgress ||
                s.Status == SessionStatus.RecordingComplete);
        }
        catch (PabloException)
        {
            ErrorMessage = "Failed to load today's sessions.";
        }
        catch (Exception)
        {
            ErrorMessage = "Failed to load sessions. Check your connection.";
        }
        finally
        {
            IsLoading = false;
        }
    }

    [RelayCommand]
    public async Task StartSessionAsync(string sessionId)
    {
        if (await MarkInProgressAndLaunchAsync(sessionId) is null) return;

        // Start recording
        _ = _recorder.StartForSessionAsync(sessionId);

        await LoadTodaySessionsAsync();
    }

    /// <summary>
    /// Marks the session in progress and opens its video call. Null when the
    /// PATCH failed (the error is already on <see cref="ErrorMessage"/>).
    /// </summary>
    private async Task<Session?> MarkInProgressAndLaunchAsync(string sessionId)
    {
        try
        {
            var session = await _apiClient.UpdateSessionStatusAsync(sessionId, SessionStatus.InProgress);
            ActiveSession = session;
            _videoLaunch.LaunchVideoCall(session.VideoLink, session.VideoPlatform?.ToString());
            return session;
        }
        catch (PabloException ex) when (IsSubscriptionRefusal(ex))
        {
            SubscriptionBlocked = true;
            ErrorMessage = "Your subscription needs attention. Please update your billing.";
            return null;
        }
        catch (PabloException)
        {
            ErrorMessage = "Failed to start session.";
            return null;
        }
    }

    [RelayCommand]
    public async Task EndSessionAsync(string sessionId)
    {
        // Stop recording first.
        try
        {
            if (_recordingVm.State != Models.RecordingUIState.Idle)
                await _recordingVm.StopRecordingAsync();
        }
        catch (Exception ex)
        {
            App.LogException("EndSessionAsync.StopRecording", ex);
            // Continue — we still want to enqueue any partial recording for upload.
        }

        // PATCH status BEFORE the upload — the backend's /upload-audio route
        // (sessions.py:594-604) rejects anything outside {recording_complete,
        // transcribing, failed} with 400 INVALID_STATUS. The audio's on-disk
        // durability does NOT depend on doing the PATCH last: UploadAudioAsync
        // enqueues to PendingTranscriptionStore before its network call
        // (TranscriptionViewModel.cs:83-87), and UploadFromPendingAsync now
        // self-heals from INVALID_STATUS, so a failed PATCH still recovers on
        // the next ResumePendingUploadsAsync pass.
        try
        {
            await _apiClient.UpdateSessionStatusAsync(sessionId, SessionStatus.RecordingComplete);
        }
        catch (PabloException ex)
        {
            App.LogException("EndSessionAsync.UpdateSessionStatus", ex);
            ErrorMessage = "Failed to mark session complete.";
            // Fall through — UploadAudioAsync still enqueues so we don't lose
            // the audio. The pending-store retry loop will re-attempt the PATCH
            // via the INVALID_STATUS self-heal on the next pass.
        }

        await _transcriptionVm.UploadAudioAsync(sessionId);

        ActiveSession = null;
        await LoadTodaySessionsAsync();
    }

    [RelayCommand]
    public async Task CreateAdHocSessionAsync(string patientId)
    {
        try
        {
            var request = new CreateSessionRequest(
                PatientId: patientId,
                ScheduledAt: DateTimeOffset.UtcNow.ToString("o"),
                DurationMinutes: 50,
                VideoLink: null,
                VideoPlatform: null,
                SessionType: SessionType.Individual,
                Source: SessionSource.Companion,
                Notes: null
            );

            var session = await _apiClient.CreateSessionAsync(request);
            await StartSessionAsync(session.Id);
        }
        catch (PabloException ex) when (IsSubscriptionRefusal(ex))
        {
            SubscriptionBlocked = true;
            ErrorMessage = "Your subscription needs attention. Please update your billing.";
        }
        catch (PabloException)
        {
            ErrorMessage = "Failed to create session.";
        }
    }

    // --- Session History ---

    [RelayCommand]
    public async Task LoadSessionsAsync()
    {
        _historyPage = 1;
        IsLoadingHistory = true;
        HistoryErrorMessage = null;

        try
        {
            var response = await _apiClient.FetchSessionsAsync(_historyPage, HistoryPageSize, StatusFilter);
            Sessions = response.Data;
            TotalSessions = response.Total;
            HasMoreSessions = response.HasMore;
        }
        catch (PabloException)
        {
            HistoryErrorMessage = "Failed to load session history.";
        }
        catch (Exception)
        {
            HistoryErrorMessage = "Failed to load sessions. Check your connection.";
        }
        finally
        {
            IsLoadingHistory = false;
        }
    }

    [RelayCommand]
    public async Task LoadMoreSessionsAsync()
    {
        if (!HasMoreSessions || IsLoadingHistory) return;

        _historyPage++;
        IsLoadingHistory = true;

        try
        {
            var response = await _apiClient.FetchSessionsAsync(_historyPage, HistoryPageSize, StatusFilter);
            Sessions = [.. Sessions, .. response.Data];
            TotalSessions = response.Total;
            HasMoreSessions = response.HasMore;
        }
        catch (PabloException)
        {
            HistoryErrorMessage = "Failed to load more sessions.";
        }
        finally
        {
            IsLoadingHistory = false;
        }
    }

    partial void OnStatusFilterChanged(string? value)
    {
        _ = LoadSessionsAsync();
    }

    // --- Polling ---

    public void StartPolling()
    {
        StopPolling();
        _pollingTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(30) };
        _pollingTimer.Tick += async (_, _) =>
        {
            if (IsLoading) return;
            await LoadTodaySessionsAsync();
        };
        _pollingTimer.Start();
    }

    public void StopPolling()
    {
        _pollingTimer?.Stop();
        _pollingTimer = null;
    }

    /// <summary>
    /// Loads today's appointments now and every <see cref="AppointmentRefreshInterval"/>
    /// until <see cref="StopAppointmentRefresh"/> (sign-out). Must be called on
    /// the UI thread.
    /// </summary>
    public void StartAppointmentRefresh()
    {
        StopAppointmentRefresh();
        _appointmentRefreshTimer = new DispatcherTimer { Interval = AppointmentRefreshInterval };
        _appointmentRefreshTimer.Tick += async (_, _) =>
        {
            if (IsLoadingAppointments) return;
            await LoadTodayAppointmentsAsync();
        };
        _appointmentRefreshTimer.Start();
        _ = LoadTodayAppointmentsAsync();
    }

    public void StopAppointmentRefresh()
    {
        _appointmentRefreshTimer?.Stop();
        _appointmentRefreshTimer = null;
    }
}

/// <summary>How a start from an appointment ended.</summary>
public enum AppointmentStartKind
{
    /// <summary>Another start was in flight, or a recording is live: nothing was done.</summary>
    Busy,

    /// <summary>The session was created and marked in progress.</summary>
    Started,

    /// <summary>The server refused: the client declined AI-assisted notes. Nothing was created.</summary>
    Declined,

    /// <summary>
    /// The server refused a telehealth start: nobody has asked the client about
    /// AI-assisted notes and the start did not say it is asking. Nothing was created.
    /// </summary>
    ConsentNeeded,

    /// <summary>Any other failure; the message is on <see cref="SessionViewModel.ErrorMessage"/>.</summary>
    Failed,
}

/// <param name="Kind">How the start ended.</param>
/// <param name="SessionId">The session created, when one was.</param>
/// <param name="DeclinedOn">For <see cref="AppointmentStartKind.Declined"/>, the day the client
/// declined as <c>YYYY-MM-DD</c>, or empty when the server sent none.</param>
/// <param name="Recording">For <see cref="AppointmentStartKind.Started"/>, whether capture is running.</param>
public sealed record AppointmentStartOutcome(
    AppointmentStartKind Kind,
    string? SessionId = null,
    string? DeclinedOn = null,
    bool Recording = false)
{
    public static readonly AppointmentStartOutcome Busy = new(AppointmentStartKind.Busy);

    /// <summary>Whether this call did the start (it was not refused as busy).</summary>
    public bool Ran => Kind != AppointmentStartKind.Busy;
}
