using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Xaml;
using PabloCompanion.Services;
using uniffi.pablo_core;

namespace PabloCompanion.ViewModels;

/// <summary>
/// Manages session lifecycle, today's sessions, and session history.
/// Mirrors SessionViewModel.swift on macOS.
/// </summary>
public partial class SessionViewModel : ObservableObject
{
    private readonly APIClient _apiClient;
    private readonly VideoLaunchService _videoLaunch;
    private DispatcherTimer? _pollingTimer;

    [ObservableProperty]
    public partial Session[] TodaySessions { get; set; } = [];

    [ObservableProperty]
    public partial bool IsLoading { get; set; }

    [ObservableProperty]
    public partial string? ErrorMessage { get; set; }

    [ObservableProperty]
    public partial Session? ActiveSession { get; set; }

    public SessionViewModel(APIClient apiClient, VideoLaunchService videoLaunch)
    {
        _apiClient = apiClient;
        _videoLaunch = videoLaunch;
    }

    [RelayCommand]
    public async Task LoadTodaySessionsAsync()
    {
        IsLoading = true;
        ErrorMessage = null;

        try
        {
            // Windows uses its own timezone IDs; backend expects IANA format
            var timezone = TimeZoneInfo.TryConvertWindowsIdToIanaId(TimeZoneInfo.Local.Id, out var iana)
                ? iana
                : TimeZoneInfo.Local.Id;
            var sessions = await _apiClient.FetchTodaySessionsAsync(timezone);
            TodaySessions = sessions;

            // Track active session
            ActiveSession = sessions.FirstOrDefault(s =>
                s.Status == SessionStatus.InProgress ||
                s.Status == SessionStatus.RecordingComplete);
        }
        catch (PabloException ex)
        {
            ErrorMessage = ex.Message;
        }
        catch (Exception ex)
        {
            var inner = ex.InnerException?.Message ?? ex.Message;
            ErrorMessage = $"Failed to load sessions: {inner}";
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

            // Launch video call if configured
            _videoLaunch.LaunchVideoCall(session.VideoLink, session.VideoPlatform?.ToString());

            await LoadTodaySessionsAsync();
        }
        catch (PabloException ex)
        {
            ErrorMessage = ex.Message;
        }
    }

    [RelayCommand]
    public async Task EndSessionAsync(string sessionId)
    {
        try
        {
            await _apiClient.UpdateSessionStatusAsync(sessionId, SessionStatus.RecordingComplete);
            ActiveSession = null;
            await LoadTodaySessionsAsync();
        }
        catch (PabloException ex)
        {
            ErrorMessage = ex.Message;
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
        catch (PabloException ex)
        {
            ErrorMessage = ex.Message;
        }
    }

    public void StartPolling()
    {
        StopPolling();
        _pollingTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(30) };
        _pollingTimer.Tick += async (_, _) => await LoadTodaySessionsAsync();
        _pollingTimer.Start();
    }

    public void StopPolling()
    {
        _pollingTimer?.Stop();
        _pollingTimer = null;
    }
}
