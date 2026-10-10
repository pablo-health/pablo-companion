using System.Net.Http;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Xaml;
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

    public SessionViewModel(APIClient apiClient, VideoLaunchService videoLaunch,
        RecordingViewModel recordingVm, TranscriptionViewModel transcriptionVm)
    {
        _apiClient = apiClient;
        _videoLaunch = videoLaunch;
        _recordingVm = recordingVm;
        _transcriptionVm = transcriptionVm;
    }

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
    /// session. Returns whether this call did the start.
    /// </summary>
    public async Task<bool> StartAppointmentSessionAsync(string appointmentId)
    {
        if (StartingAppointmentId is not null) return false;
        if (_recordingVm.State != RecordingUIState.Idle || _recordingVm.ActiveSessionId is not null) return false;

        StartingAppointmentId = appointmentId;
        try
        {
            var session = await StartSessionFromAppointmentAsync(appointmentId);
            if (session is null) return true;
            await StartSessionAsync(session.Id);
            return true;
        }
        finally
        {
            StartingAppointmentId = null;
            // Pick up the session link and its in-progress status.
            await LoadTodayAppointmentsAsync();
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
        catch (InvalidOperationException ex) when (ex.Message.Contains("(403)"))
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
        try
        {
            var session = await _apiClient.UpdateSessionStatusAsync(sessionId, SessionStatus.InProgress);
            ActiveSession = session;
            _videoLaunch.LaunchVideoCall(session.VideoLink, session.VideoPlatform?.ToString());

            // Start recording
            _ = _recordingVm.StartRecordingAsync(sessionId);

            await LoadTodaySessionsAsync();
        }
        catch (InvalidOperationException ex) when (ex.Message.Contains("(403)"))
        {
            SubscriptionBlocked = true;
            ErrorMessage = "Your subscription needs attention. Please update your billing.";
        }
        catch (PabloException)
        {
            ErrorMessage = "Failed to start session.";
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
        catch (InvalidOperationException ex) when (ex.Message.Contains("(403)"))
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
