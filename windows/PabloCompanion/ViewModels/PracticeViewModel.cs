using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using PabloCompanion.Models;
using PabloCompanion.Services;

namespace PabloCompanion.ViewModels;

/// <summary>
/// Orchestrates a practice session: topic selection → WebSocket connection →
/// mic capture → audio playback → session teardown.
/// </summary>
public sealed partial class PracticeViewModel : ObservableObject, IDisposable
{
    // ── State ───────────────────────────────────────────────────────────────

    public enum Phase { Idle, LoadingTopics, PickingTopic, Connecting, Active, Ending, Ended, Error }

    [ObservableProperty]
    public partial Phase CurrentPhase { get; set; } = Phase.Idle;

    [ObservableProperty]
    public partial PracticeTopic[] Topics { get; set; } = [];

    [ObservableProperty]
    public partial PracticeTopic? SelectedTopic { get; set; }

    [ObservableProperty]
    public partial string? SessionId { get; set; }

    [ObservableProperty]
    public partial int DurationSeconds { get; set; }

    [ObservableProperty]
    public partial float MicLevel { get; set; }

    [ObservableProperty]
    public partial float PabloLevel { get; set; }

    [ObservableProperty]
    public partial PracticeWebSocketClient.PabloState PabloState { get; set; } = PracticeWebSocketClient.PabloState.Listening;

    [ObservableProperty]
    public partial string? ErrorMessage { get; set; }

    [ObservableProperty]
    public partial int EndedDurationSeconds { get; set; }

    // ── Dependencies ────────────────────────────────────────────────────────

    private readonly PracticeApiClient _apiClient;
    private readonly PracticeWebSocketClient _wsClient = new();
    private readonly PracticeMicCapture _micCapture = new();
    private readonly PracticeAudioPlayer _audioPlayer = new();

    private CancellationTokenSource? _durationCts;
    private CancellationTokenSource? _reconnectCts;
    private DateTime? _sessionStartTime;
    private int _reconnectAttempts;
    private const int MaxReconnectAttempts = 3;

    /// <summary>
    /// The mic device ID to use (from RecordingViewModel's selected device).
    /// </summary>
    public string? SelectedMicId { get; set; }

    public bool IsSessionActive => CurrentPhase is Phase.Active or Phase.Ending or Phase.Connecting;

    public PracticeViewModel(PracticeApiClient apiClient)
    {
        _apiClient = apiClient;
        ConfigureCallbacks();
    }

    // ── Topic loading ───────────────────────────────────────────────────────

    [RelayCommand]
    private async Task LoadTopicsAsync()
    {
        CurrentPhase = Phase.LoadingTopics;
        try
        {
            Topics = await _apiClient.FetchTopicsAsync();
            CurrentPhase = Phase.PickingTopic;
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Failed to load practice topics: {ex.Message}";
            CurrentPhase = Phase.Idle;
        }
    }

    // ── Session lifecycle ───────────────────────────────────────────────────

    [RelayCommand]
    private async Task StartSessionAsync(PracticeTopic topic)
    {
        App.Log($"[Practice] StartSessionAsync topic={topic.Id} ({topic.Name})");
        SelectedTopic = topic;
        CurrentPhase = Phase.Connecting;

        try
        {
            // 1. Create session via REST
            App.Log($"[Practice] POST /api/practice/sessions baseUrl={_apiClient.BaseUrl}");
            var response = await _apiClient.CreateSessionAsync(topic.Id);
            SessionId = response.SessionId;
            App.Log($"[Practice] CreateSession ok session={response.SessionId} ticket.len={response.WsTicket.Length}");

            // 2. Connect WebSocket
            var wsUri = _apiClient.BuildWebSocketUri(response.WsTicket);
            App.Log($"[Practice] ws connect → {wsUri.Host}:{wsUri.Port}{wsUri.AbsolutePath}");
            await _wsClient.ConnectAsync(wsUri);
            App.Log($"[Practice] ws connect returned, state={_wsClient.State}");

            // 3. Start mic capture
            _micCapture.Start(SelectedMicId);
            App.Log($"[Practice] mic started (deviceId={SelectedMicId ?? "default"})");

            // 4. Start audio player
            _audioPlayer.Start();
            App.Log("[Practice] audio player started");

            // 5. Wait briefly for auth, then send session_start
            await Task.Delay(500);
            _wsClient.StartSession(response.SessionId);
            App.Log($"[Practice] sent session_start session={response.SessionId}");
        }
        catch (Exception ex)
        {
            App.LogException("[Practice] StartSessionAsync failed", ex);
            Cleanup();
            ErrorMessage = $"Failed to start practice session: {ex.Message}";
            CurrentPhase = Phase.Idle;
        }
    }

    [RelayCommand]
    private void EndSession()
    {
        if (CurrentPhase != Phase.Active) return;
        CurrentPhase = Phase.Ending;
        _wsClient.EndSession();
    }

    [RelayCommand]
    private void PauseAudio() => _wsClient.PauseAudio();

    [RelayCommand]
    private void ResumeAudio() => _wsClient.ResumeAudio();

    [RelayCommand]
    private void Dismiss()
    {
        Cleanup();
        CurrentPhase = Phase.Idle;
        SelectedTopic = null;
        SessionId = null;
        DurationSeconds = 0;
    }

    // ── Callbacks ───────────────────────────────────────────────────────────

    private void ConfigureCallbacks()
    {
        _wsClient.ConnectionStateChanged += OnConnectionStateChanged;
        _wsClient.PabloStateChanged += state => DispatcherQueue(() => PabloState = state);
        _wsClient.AudioReceived += OnAudioReceived;
        _wsClient.SessionStarted += OnSessionStarted;
        _wsClient.SessionEnded += OnSessionEnded;
        _wsClient.ErrorOccurred += OnError;

        _micCapture.AudioFrameReady += frame => _wsClient.SendAudioFrame(frame);
        _micCapture.LevelUpdated += level => DispatcherQueue(() => MicLevel = level);
        _audioPlayer.LevelUpdated += level => DispatcherQueue(() => PabloLevel = level);
    }

    private void OnConnectionStateChanged(PracticeWebSocketClient.ConnectionState state)
    {
        DispatcherQueue(() =>
        {
            if (state == PracticeWebSocketClient.ConnectionState.Disconnected && CurrentPhase == Phase.Active)
            {
                AttemptReconnection();
            }
            else if (state == PracticeWebSocketClient.ConnectionState.Active)
            {
                _reconnectAttempts = 0;
            }
        });
    }

    private void OnAudioReceived(byte[] pcmData, bool isFinal)
    {
        _audioPlayer.Enqueue(pcmData);
        if (isFinal)
        {
            DispatcherQueue(() => PabloState = PracticeWebSocketClient.PabloState.Listening);
        }
    }

    private void OnSessionStarted(string sessionId)
    {
        DispatcherQueue(() =>
        {
            SessionId = sessionId;
            CurrentPhase = Phase.Active;
            _sessionStartTime = DateTime.UtcNow;
            StartDurationTimer();
        });
    }

    private void OnSessionEnded(int durationSeconds)
    {
        DispatcherQueue(() =>
        {
            Cleanup();
            EndedDurationSeconds = durationSeconds;
            CurrentPhase = Phase.Ended;
        });
    }

    private void OnError(string message, bool fatal)
    {
        DispatcherQueue(() =>
        {
            if (fatal)
            {
                Cleanup();
                CurrentPhase = Phase.Error;
            }
            ErrorMessage = message;
        });
    }

    // ── Reconnection ────────────────────────────────────────────────────────

    private void AttemptReconnection()
    {
        if (SessionId == null || _reconnectAttempts >= MaxReconnectAttempts)
        {
            Cleanup();
            ErrorMessage = "Connection lost";
            CurrentPhase = Phase.Error;
            return;
        }

        _reconnectAttempts++;
        CurrentPhase = Phase.Connecting;

        var lastSeq = _wsClient.LastReceivedSequence;
        var sessionId = SessionId!;

        _reconnectCts?.Cancel();
        _reconnectCts = new CancellationTokenSource();
        var ct = _reconnectCts.Token;

        _ = Task.Run(async () =>
        {
            // Exponential backoff: 0.5s, 1s, 2s
            var delay = (int)(500 * Math.Pow(2, _reconnectAttempts - 1));
            await Task.Delay(delay, ct);
            if (ct.IsCancellationRequested) return;

            try
            {
                var ticket = await _apiClient.FetchTicketAsync();
                var wsUri = _apiClient.BuildWebSocketUri(ticket);

                _wsClient.Disconnect(forReconnect: true);
                await _wsClient.ConnectAsync(wsUri);

                await Task.Delay(500, ct);
                if (ct.IsCancellationRequested) return;

                _wsClient.ResumeSession(sessionId, lastSeq);
            }
            catch
            {
                if (!ct.IsCancellationRequested)
                {
                    DispatcherQueue(AttemptReconnection);
                }
            }
        }, ct);
    }

    // ── Duration timer ──────────────────────────────────────────────────────

    private void StartDurationTimer()
    {
        _durationCts?.Cancel();
        _durationCts = new CancellationTokenSource();
        var ct = _durationCts.Token;

        _ = Task.Run(async () =>
        {
            while (!ct.IsCancellationRequested)
            {
                await Task.Delay(1000, ct);
                if (ct.IsCancellationRequested || _sessionStartTime == null) break;
                var elapsed = (int)(DateTime.UtcNow - _sessionStartTime.Value).TotalSeconds;
                DispatcherQueue(() => DurationSeconds = elapsed);
            }
        }, ct);
    }

    // ── Cleanup ─────────────────────────────────────────────────────────────

    private void Cleanup()
    {
        _reconnectCts?.Cancel();
        _reconnectCts = null;
        _reconnectAttempts = 0;
        _durationCts?.Cancel();
        _durationCts = null;
        _micCapture.Stop();
        _audioPlayer.Stop();
        _wsClient.Disconnect();
        MicLevel = 0;
        PabloLevel = 0;
        PabloState = PracticeWebSocketClient.PabloState.Listening;
    }

    public void Dispose()
    {
        Cleanup();
        _wsClient.Dispose();
        _micCapture.Dispose();
        _audioPlayer.Dispose();
    }

    // ── Dispatcher helper ───────────────────────────────────────────────────

    private static void DispatcherQueue(Action action)
    {
        if (Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread() != null)
        {
            action();
        }
        else
        {
            App.UiDispatcherQueue?.TryEnqueue(() => action());
        }
    }
}
