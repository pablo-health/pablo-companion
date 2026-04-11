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
    private readonly PendingTranscriptionStore _pendingStore;
    private DispatcherTimer? _pollingTimer;

    // --- Today's sessions ---

    [ObservableProperty]
    public partial Session[] TodaySessions { get; set; } = [];

    [ObservableProperty]
    public partial bool IsLoading { get; set; }

    [ObservableProperty]
    public partial string? ErrorMessage { get; set; }

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
        RecordingViewModel recordingVm, TranscriptionViewModel transcriptionVm,
        PendingTranscriptionStore pendingStore)
    {
        _apiClient = apiClient;
        _videoLaunch = videoLaunch;
        _recordingVm = recordingVm;
        _transcriptionVm = transcriptionVm;
        _pendingStore = pendingStore;
    }

    /// <summary>
    /// Clears all session data. Called on sign-out to prevent PHI leakage.
    /// </summary>
    public void ClearAllData()
    {
        StopPolling();
        TodaySessions = [];
        Sessions = [];
        ActiveSession = null;
        TotalSessions = 0;
        HasMoreSessions = false;
        StatusFilter = null;
        ErrorMessage = null;
        HistoryErrorMessage = null;
    }

    // --- Today ---

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
        catch (PabloException)
        {
            ErrorMessage = "Failed to start session.";
        }
    }

    [RelayCommand]
    public async Task EndSessionAsync(string sessionId)
    {
        try
        {
            // Stop recording first
            if (_recordingVm.State != Models.RecordingUIState.Idle)
                await _recordingVm.StopRecordingAsync();

            await _apiClient.UpdateSessionStatusAsync(sessionId, SessionStatus.RecordingComplete);
            ActiveSession = null;

            // Upload audio to backend for server-side transcription (default on Windows).
            // Falls back to local transcription if upload fails and auto-transcribe is on.
            if (_transcriptionVm.AutoTranscribe)
            {
                _pendingStore.Add(sessionId, _transcriptionVm.QualityPreset);
                _ = _transcriptionVm.UploadAudioAsync(sessionId);
            }

            await LoadTodaySessionsAsync();
        }
        catch (PabloException)
        {
            ErrorMessage = "Failed to end session.";
        }
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
}
