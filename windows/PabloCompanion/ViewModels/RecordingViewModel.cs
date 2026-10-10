using AudioCapture.Models;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using PabloCompanion.Helpers;
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
    private readonly SynchronizationContext? _uiContext;
    private DispatcherTimer? _levelTimer;
    private DispatcherTimer? _durationTimer;
    private bool _starting;
    private int _liveCapture = -1;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Trouble))]
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

    /// <summary>
    /// Why the last start (or stop) failed, for the main window's alert. A start
    /// that fails lets the session go, so this is not trouble on the card.
    /// </summary>
    [ObservableProperty]
    public partial string? ErrorMessage { get; set; }

    /// <summary>
    /// True when the failure in <see cref="ErrorMessage"/> or
    /// <see cref="PersistentError"/> is Windows refusing the microphone, so the
    /// window can offer to open the privacy setting.
    /// </summary>
    [ObservableProperty]
    public partial bool ErrorIsMicrophonePermission { get; set; }

    /// <summary>
    /// The session capture is recording for. Set once capture is running, and
    /// kept while the session is open even if capture stops on its own.
    /// </summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Trouble))]
    public partial string? ActiveSessionId { get; set; }

    /// <summary>
    /// True while the capture has stopped writing audio to disk. Drives the
    /// stall warning; mirrors <c>recordingStalled</c> on macOS.
    /// </summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Trouble))]
    public partial bool RecordingStalled { get; set; }

    /// <summary>
    /// Set when the mic disappears mid-session and capture stops; cleared by the
    /// next start or restart. See <see cref="Trouble"/>.
    /// </summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Trouble))]
    public partial bool MicDisconnected { get; set; }

    /// <summary>
    /// Why capture stopped while the session is still open (a capture failure, or
    /// a restart that didn't start). Cleared by the next start or restart.
    /// </summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Trouble))]
    public partial string? PersistentError { get; set; }

    /// <summary>System audio has stopped reaching the recording; the mic is still recording.</summary>
    [ObservableProperty]
    public partial bool SystemAudioInterrupted { get; set; }

    /// <summary>What the session card has to say about capture; null when recording is fine or no session is open.</summary>
    public RecordingTrouble? Trouble => RecordingTrouble.Evaluate(
        ActiveSessionId, State, RecordingStalled, MicDisconnected, PersistentError);

    public RecordingViewModel(RecordingService recordingService, SessionRecordingStore store)
    {
        _recordingService = recordingService;
        _store = store;
        _uiContext = SynchronizationContext.Current;

        // Raised from the watchdog's timer thread and from capture threads; state
        // changes go back to the thread this was created on (the UI thread).
        _recordingService.RecordingStalled += (_, _) => OnUi(() => RecordingStalled = true);
        _recordingService.RecordingResumed += (_, _) => OnUi(() => RecordingStalled = false);
        _recordingService.SystemAudioInterrupted += (_, _) => OnUi(() => SystemAudioInterrupted = true);
        _recordingService.SystemAudioRestored += (_, _) => OnUi(() => SystemAudioInterrupted = false);
        _recordingService.CaptureStopped += (_, e) => OnUi(() => HandleCaptureStopped(e));
    }

    /// <summary>
    /// Starts capture for <paramref name="sessionId"/> and returns once it is
    /// recording. If capture doesn't start, the session is let go again, so
    /// nothing shows a recording that isn't happening; the reason is in
    /// <see cref="ErrorMessage"/>. Mirrors <c>startRecording(forSession:)</c>.
    /// </summary>
    public async Task<bool> StartRecordingForSessionAsync(string sessionId)
    {
        if (_starting || State != RecordingUIState.Idle || ActiveSessionId is not null) return false;

        _starting = true;
        try
        {
            Duration = 0;
            var started = await StartCaptureAsync(sessionId, restart: false);
            if (!started) ActiveSessionId = null;
            return started;
        }
        finally
        {
            _starting = false;
        }
    }

    /// <summary>
    /// Restart Recording: for a stalled or stopped capture in the open session.
    /// Stops what is left of the capture, then captures again into the same
    /// sidecars, so what was already recorded is kept and added to. The session
    /// stays open whatever happens; a restart that fails shows as trouble.
    /// </summary>
    [RelayCommand]
    public async Task RestartRecordingAsync()
    {
        if (_starting || ActiveSessionId is not { } sessionId) return;

        _starting = true;
        try
        {
            StopTimers();
            try
            {
                if (await _recordingService.TryStopAsync(sessionId) is { } recording)
                    _store.Save(sessionId, recording);
            }
            catch (Exception ex)
            {
                App.Log($"RestartRecording: stop failed type={ex.GetType().Name}");
            }
            State = RecordingUIState.Idle;

            await StartCaptureAsync(sessionId, restart: true);
        }
        finally
        {
            _starting = false;
        }
    }

    private async Task<bool> StartCaptureAsync(string sessionId, bool restart)
    {
        ErrorMessage = null;
        ErrorIsMicrophonePermission = false;
        PersistentError = null;
        MicDisconnected = false;
        RecordingStalled = false;
        SystemAudioInterrupted = false;

        try
        {
            await _recordingService.StartAsync(sessionId, SelectedMicId, exportRawPcm: true);
            _liveCapture = _recordingService.CurrentCapture;
            ActiveSessionId = sessionId;
            State = RecordingUIState.Recording;
            StartTimers();
            return true;
        }
        catch (Exception ex)
        {
            App.Log($"Recording start failed type={ex.GetType().Name} restart={restart}");
            var failure = RecordingStartFailure.Describe(ex);
            ErrorIsMicrophonePermission = failure.IsMicrophonePermission;
            if (restart)
                PersistentError = failure.Message;
            else
                ErrorMessage = failure.Message;
            State = RecordingUIState.Idle;
            StopTimers();
            return false;
        }
    }

    /// <summary>
    /// Ends capture for the open session (End Session) and lets the session go.
    /// Also covers a capture that already stopped on its own.
    /// </summary>
    [RelayCommand]
    public async Task StopRecordingAsync()
    {
        if (State == RecordingUIState.Idle && ActiveSessionId is null) return;

        var sessionId = ActiveSessionId;
        try
        {
            StopTimers();
            var recording = await _recordingService.TryStopAsync(sessionId);
            if (sessionId != null && recording != null)
                _store.Save(sessionId, recording);
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
            MicDisconnected = false;
            PersistentError = null;
            SystemAudioInterrupted = false;
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

    /// <summary>Clears the main window's alert.</summary>
    public void DismissError()
    {
        ErrorMessage = null;
        if (PersistentError is null) ErrorIsMicrophonePermission = false;
    }

    [RelayCommand]
    public async Task LoadAudioDevicesAsync()
    {
        try
        {
            var devices = await _recordingService.GetAvailableDevicesAsync();
            AvailableMics = devices.Where(d => d.SourceType == AudioTrackType.Mic).ToArray();

            // Nothing is selected on the therapist's behalf: no selection records the
            // Windows default mic as it is at each start, where selecting the current
            // default's id here would pin that device even after the default moves.
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
        try
        {
            StopTimers();
            _recordingService.Dispose();
        }
        catch { /* best effort */ }

        _store.Clear();
        State = RecordingUIState.Idle;
        RecordingStalled = false;
        MicDisconnected = false;
        PersistentError = null;
        SystemAudioInterrupted = false;
        Duration = 0;
        MicLevel = 0;
        SystemLevel = 0;
        PeakMicLevel = 0;
        PeakSystemLevel = 0;
        ActiveSessionId = null;
        ErrorMessage = null;
        ErrorIsMicrophonePermission = false;
    }

    /// <summary>
    /// The capture ended on its own (mic disconnected, capture failed). Keep what
    /// it saved, and show the session's capture as stopped with its reason; the
    /// session stays open for Restart Recording or End Session.
    /// </summary>
    private void HandleCaptureStopped(CaptureStoppedEventArgs e)
    {
        if (e.Recording is { } recording)
            _store.Save(e.SessionId, recording);

        // Ended, or restarted, in the meantime: nothing left to report.
        if (ActiveSessionId != e.SessionId || e.Capture != _liveCapture || State == RecordingUIState.Idle) return;

        StopTimers();
        State = RecordingUIState.Idle;
        RecordingStalled = false;
        MicLevel = 0;
        SystemLevel = 0;
        PeakMicLevel = 0;
        PeakSystemLevel = 0;
        if (e.Reason == CaptureStopReason.MicDisconnected)
            MicDisconnected = true;
        else
            PersistentError = e.Message ?? RecordingTrouble.CaptureFailedMessage;
    }

    private void OnUi(Action action)
    {
        if (_uiContext is null) action();
        else _uiContext.Post(_ => action(), null);
    }

    private void StartTimers()
    {
        // DispatcherTimer needs the UI thread's dispatcher; without one (tests),
        // there are no levels or duration to drive.
        if (SynchronizationContext.Current is not DispatcherQueueSynchronizationContext) return;

        StopTimers();

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
