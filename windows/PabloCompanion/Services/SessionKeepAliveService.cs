namespace PabloCompanion.Services;

/// <summary>
/// Keeps the backend idle session alive for the duration of a recording.
///
/// During a recording the app makes no other backend calls (capture is local;
/// upload happens at stop), so without a deliberate heartbeat the server-side
/// idle timeout can tombstone the session right before the stop-time upload.
/// An active recording is genuine user activity — the local inactivity lock is
/// already suspended while recording — so the server session should stay alive
/// too. Mirrors <c>SessionViewModel.keepSessionAliveWhileRecording</c> on macOS.
///
/// <see cref="Start"/> begins with a read-only liveness probe so a session that
/// is already dead surfaces the re-auth flow immediately; each subsequent touch
/// that hits a 401 does the same via <see cref="APIClient.UnauthenticatedDetected"/>.
/// Other failures are swallowed — the next tick retries, and a lost heartbeat
/// must never interfere with the recording itself.
/// </summary>
public class SessionKeepAliveService : IDisposable
{
    /// <summary>
    /// How often to refresh the server-side idle heartbeat. The server window
    /// is 15 minutes; 4 minutes keeps a comfortable margin even if one touch
    /// is lost to a network blip.
    /// </summary>
    public static readonly TimeSpan TouchInterval = TimeSpan.FromMinutes(4);

    private readonly APIClient _apiClient;
    private readonly TimeSpan _interval;
    private Timer? _timer;

    public SessionKeepAliveService(APIClient apiClient)
        : this(apiClient, TouchInterval)
    {
    }

    /// <summary>Interval-injectable overload for tests.</summary>
    internal SessionKeepAliveService(APIClient apiClient, TimeSpan interval)
    {
        _apiClient = apiClient;
        _interval = interval;
    }

    public bool IsRunning => _timer != null;

    /// <summary>
    /// Starts the heartbeat: probes liveness now, then touches the session on
    /// every interval until <see cref="Stop"/>. Idempotent while running.
    /// </summary>
    public void Start()
    {
        if (_timer != null) return;
        _ = _apiClient.VerifySessionAliveAsync();
        _timer = new Timer(async _ => await TickAsync(), null, _interval, _interval);
    }

    public void Stop()
    {
        _timer?.Dispose();
        _timer = null;
    }

    internal async Task TickAsync()
    {
        try
        {
            await _apiClient.TouchSessionAsync();
        }
        catch (Exception ex)
        {
            // A 401 has already raised UnauthenticatedDetected inside APIClient;
            // anything else (network blip, suspend) just waits for the next tick.
            App.LogException("SessionKeepAliveService.TickAsync", ex);
        }
    }

    public void Dispose() => Stop();
}
