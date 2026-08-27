namespace PabloCompanion.Services;

/// <summary>
/// Periodically drains the pending-upload queue and reconciles awaiting-note
/// entries, so a session that finishes while the app stays open gets its audio
/// uploaded — and, once the backend has produced the note, deleted — without
/// waiting for the next launch.
///
/// Mirrors the 5-minute <c>.task</c> loop that drives
/// <c>retryPendingAudioUploads()</c> on macOS (<c>ContentView.swift</c>).
/// Launch-time orphan adoption stays in <c>App.OnLaunched</c>; this timer only
/// runs the drain + reconcile pass, matching the macOS timer.
///
/// The pass is injected as a delegate so this stays free of the ViewModel layer
/// and is trivially testable without launching the app.
/// </summary>
public class PendingUploadScheduler : IDisposable
{
    /// <summary>
    /// How often to drain + reconcile. Matches the macOS 5-minute cadence
    /// (<c>ContentView.swift</c>: <c>Task.sleep(for: .seconds(300))</c>).
    /// </summary>
    public static readonly TimeSpan Interval = TimeSpan.FromMinutes(5);

    private readonly Func<Task> _pass;
    private readonly TimeSpan _interval;
    private Timer? _timer;

    public PendingUploadScheduler(Func<Task> pass)
        : this(pass, Interval)
    {
    }

    /// <summary>Interval-injectable overload for tests.</summary>
    internal PendingUploadScheduler(Func<Task> pass, TimeSpan interval)
    {
        _pass = pass;
        _interval = interval;
    }

    public bool IsRunning => _timer != null;

    /// <summary>
    /// Starts the periodic pass. The first tick fires one interval from now —
    /// launch already runs an immediate pass — and repeats until
    /// <see cref="Stop"/>. Idempotent while running.
    /// </summary>
    public void Start()
    {
        if (_timer != null) return;
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
            await _pass();
        }
        catch (Exception ex)
        {
            // A failed pass must never bring down the app or halt the schedule —
            // the next tick retries. Drain and reconcile already swallow their
            // own per-entry failures; this guards the pass as a whole.
            App.LogException("PendingUploadScheduler.TickAsync", ex);
        }
    }

    public void Dispose() => Stop();
}
