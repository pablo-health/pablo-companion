using AudioCapture.Models;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Xaml;
using PabloCompanion.Models;
using PabloCompanion.Services;

namespace PabloCompanion.ViewModels;

/// <summary>
/// Manages recording state, audio levels, and device selection.
/// Singleton — shared between DayPage (banner) and SettingsPage (mic picker).
/// </summary>
public partial class RecordingViewModel : ObservableObject
{
    private readonly RecordingService _recordingService;
    private readonly SessionRecordingStore _store;
    private DispatcherTimer? _levelTimer;
    private DispatcherTimer? _durationTimer;

    [ObservableProperty]
    public partial RecordingUIState State { get; set; } = RecordingUIState.Idle;

    [ObservableProperty]
    public partial double Duration { get; set; }

    [ObservableProperty]
    public partial float MicLevel { get; set; }

    [ObservableProperty]
    public partial float SystemLevel { get; set; }

    [ObservableProperty]
    public partial float PeakMicLevel { get; set; }

    [ObservableProperty]
    public partial float PeakSystemLevel { get; set; }

    [ObservableProperty]
    public partial AudioSource[] AvailableMics { get; set; } = [];

    [ObservableProperty]
    public partial string? SelectedMicId { get; set; }

    [ObservableProperty]
    public partial bool SystemAudioActive { get; set; }

    [ObservableProperty]
    public partial string? ErrorMessage { get; set; }

    [ObservableProperty]
    public partial string? ActiveSessionId { get; set; }

    /// <summary>
    /// True while the capture has stopped writing audio to disk. Drives the
    /// stall warning on <c>DayPage</c>; mirrors <c>recordingStalled</c> on macOS.
    /// </summary>
    [ObservableProperty]
    public partial bool RecordingStalled { get; set; }

    public RecordingViewModel(RecordingService recordingService, SessionRecordingStore store)
    {
        _recordingService = recordingService;
        _store = store;

        // Raised from the watchdog's timer thread. The views that observe this VM
        // already marshal PropertyChanged onto the UI thread themselves.
        _recordingService.RecordingStalled += (_, _) => RecordingStalled = true;
        _recordingService.RecordingResumed += (_, _) => RecordingStalled = false;
    }

    [RelayCommand]
    public async Task StartRecordingAsync(string sessionId)
    {
        if (State != RecordingUIState.Idle) return;

        try
        {
            ErrorMessage = null;
            ActiveSessionId = sessionId;
            State = RecordingUIState.Recording;
            Duration = 0;
            RecordingStalled = false;

            StartTimers();

            var recording = await _recordingService.StartAsync(sessionId, SelectedMicId, exportRawPcm: true);
            _store.Save(sessionId, recording);
        }
        catch (CaptureException ex)
        {
            ErrorMessage = ex.ErrorKind switch
            {
                CaptureErrorKind.PermissionDenied => "Microphone access is required. Check Windows privacy settings.",
                CaptureErrorKind.DeviceNotAvailable => "Audio device not available. Check your microphone connection.",
                _ => $"Recording failed: {ex.Message}",
            };
            State = RecordingUIState.Idle;
            ActiveSessionId = null;
            StopTimers();
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Recording failed: {ex.Message}";
            State = RecordingUIState.Idle;
            ActiveSessionId = null;
            StopTimers();
        }
    }

    [RelayCommand]
    public async Task StopRecordingAsync()
    {
        if (State == RecordingUIState.Idle) return;

        try
        {
            StopTimers();
            var recording = await _recordingService.StopAsync();

            if (ActiveSessionId != null)
                _store.Save(ActiveSessionId, recording);
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Stop failed: {ex.Message}";
        }
        finally
        {
            State = RecordingUIState.Idle;
            ActiveSessionId = null;
            RecordingStalled = false;
            MicLevel = 0;
            SystemLevel = 0;
            PeakMicLevel = 0;
            PeakSystemLevel = 0;
        }
    }

    [RelayCommand]
    public void PauseRecording()
    {
        if (State != RecordingUIState.Recording) return;
        _recordingService.Pause();
        _durationTimer?.Stop();
        State = RecordingUIState.Paused;
    }

    [RelayCommand]
    public void ResumeRecording()
    {
        if (State != RecordingUIState.Paused) return;
        _recordingService.Resume();
        _durationTimer?.Start();
        State = RecordingUIState.Recording;
    }

    [RelayCommand]
    public async Task LoadAudioDevicesAsync()
    {
        try
        {
            var devices = await _recordingService.GetAvailableDevicesAsync();
            AvailableMics = devices.Where(d => d.SourceType == AudioTrackType.Mic).ToArray();

            // Auto-select default if nothing selected
            if (SelectedMicId == null)
            {
                var defaultMic = AvailableMics.FirstOrDefault(d => d.IsDefault);
                SelectedMicId = defaultMic?.Id ?? AvailableMics.FirstOrDefault()?.Id;
            }
        }
        catch
        {
            // Non-fatal — user can still select manually
        }
    }

    /// <summary>
    /// Stops any active recording, clears the store, and resets state.
    /// Called on sign-out to clear PHI.
    /// </summary>
    public void ClearAllData()
    {
        if (State != RecordingUIState.Idle)
        {
            try
            {
                StopTimers();
                _recordingService.Dispose();
            }
            catch { /* best effort */ }
        }

        _store.Clear();
        State = RecordingUIState.Idle;
        RecordingStalled = false;
        Duration = 0;
        MicLevel = 0;
        SystemLevel = 0;
        PeakMicLevel = 0;
        PeakSystemLevel = 0;
        ActiveSessionId = null;
        ErrorMessage = null;
    }

    private void StartTimers()
    {
        // Level polling at ~66ms (15 FPS)
        _levelTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(66) };
        _levelTimer.Tick += (_, _) =>
        {
            var levels = _recordingService.GetCurrentLevels();
            MicLevel = levels.MicLevel;
            SystemLevel = levels.SystemLevel;
            PeakMicLevel = levels.PeakMicLevel;
            PeakSystemLevel = levels.PeakSystemLevel;
            SystemAudioActive = levels.SystemLevel > 0.001f;
        };
        _levelTimer.Start();

        // Duration tracking at 1s
        _durationTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _durationTimer.Tick += (_, _) => Duration += 1;
        _durationTimer.Start();
    }

    private void StopTimers()
    {
        _levelTimer?.Stop();
        _levelTimer = null;
        _durationTimer?.Stop();
        _durationTimer = null;
    }
}
