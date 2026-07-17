namespace PabloCompanion.Services;

/// <summary>
/// Watches the mic PCM sidecar grow during a recording and raises
/// <see cref="Stalled"/> when it stops growing.
///
/// A WASAPI capture that dies mid-session is completely silent: levels read
/// zero, no exception is thrown, and nothing surfaces until the upload — by
/// which point the session is gone. File growth is the one signal that the
/// bytes are actually landing on disk, so that is what this polls.
///
/// The first check waits <see cref="FirstCheckDelay"/> to give the capture time
/// to create its files, then polls every <see cref="CheckInterval"/>. The check
/// after that establishes the size baseline, so the earliest a stall can fire is
/// two intervals in. <see cref="Stalled"/> fires once per stall — not on every
/// tick — and <see cref="Resumed"/> fires if growth comes back.
///
/// Mirrors <c>RecordingWatchdog.swift</c> on macOS.
/// </summary>
public sealed class RecordingWatchdog : IDisposable
{
    /// <summary>Delay before the first check — the capture needs time to create its files.</summary>
    public static readonly TimeSpan FirstCheckDelay = TimeSpan.FromSeconds(10);

    /// <summary>How often the mic sidecar is re-measured once monitoring is underway.</summary>
    public static readonly TimeSpan CheckInterval = TimeSpan.FromSeconds(60);

    private readonly string _recordingsDirectory;
    private readonly TimeSpan _firstCheckDelay;
    private readonly TimeSpan _checkInterval;
    private readonly object _lock = new();

    private Timer? _timer;
    private string? _micPcmPath;
    private long _lastSize;
    private bool _hasBaseline;
    private bool _stalledFired;

    /// <summary>Raised when the mic sidecar has stopped growing. Fires once per stall.</summary>
    public event EventHandler? Stalled;

    /// <summary>Raised when a stalled sidecar starts growing again.</summary>
    public event EventHandler? Resumed;

    /// <param name="recordingsDirectory">The session's output directory — where the
    /// capture writes its sidecars. May not exist yet when the watchdog starts.</param>
    public RecordingWatchdog(string recordingsDirectory)
        : this(recordingsDirectory, FirstCheckDelay, CheckInterval)
    {
    }

    /// <summary>Interval-injectable overload for tests.</summary>
    internal RecordingWatchdog(string recordingsDirectory, TimeSpan firstCheckDelay, TimeSpan checkInterval)
    {
        _recordingsDirectory = recordingsDirectory;
        _firstCheckDelay = firstCheckDelay;
        _checkInterval = checkInterval;
    }

    public bool IsRunning => _timer != null;

    /// <summary>True while the mic sidecar is known to have stopped growing.</summary>
    public bool IsStalled => _stalledFired;

    /// <summary>
    /// Starts monitoring, discarding any state from a previous run. Safe to call
    /// on an already-running watchdog — it restarts from a clean baseline, which
    /// is what a resume-after-pause wants.
    /// </summary>
    public void Start()
    {
        Stop();
        _timer = new Timer(_ => Check(), null, _firstCheckDelay, _checkInterval);
    }

    /// <summary>Stops monitoring and clears the baseline. Idempotent.</summary>
    public void Stop()
    {
        _timer?.Dispose();
        _timer = null;

        lock (_lock)
        {
            _micPcmPath = null;
            _lastSize = 0;
            _hasBaseline = false;
            _stalledFired = false;
        }
    }

    /// <summary>
    /// One poll of the mic sidecar. Never throws — a watchdog that can take the
    /// recording down with it is worse than no watchdog.
    /// </summary>
    internal void Check()
    {
        try
        {
            CheckCore();
        }
        catch (Exception ex)
        {
            App.LogException("RecordingWatchdog.Check", ex);
        }
    }

    private void CheckCore()
    {
        bool fireStalled = false;
        bool fireResumed = false;

        lock (_lock)
        {
            _micPcmPath ??= FindLatestMicPcmFile();
            if (_micPcmPath == null)
            {
                App.Log("RecordingWatchdog: no mic PCM file to monitor yet");
                return;
            }

            var currentSize = FileSizeOrZero(_micPcmPath);
            var previousSize = _lastSize;
            var hadBaseline = _hasBaseline;
            _lastSize = currentSize;
            _hasBaseline = true;

            // First sighting — only establishes the baseline. A stall needs two
            // measurements to be distinguishable from "capture hasn't written yet".
            //
            // NOTE: macOS uses `lastSize > 0` as this sentinel, which means a mic
            // file that is created and then never written stays at 0 bytes and is
            // never reported as stalled — the exact dead-capture case the watchdog
            // exists for. An explicit flag is used here so 0 -> 0 trips the stall.
            // macOS should follow.
            if (!hadBaseline) return;

            if (currentSize <= previousSize)
            {
                if (_stalledFired) return;
                _stalledFired = true;
                fireStalled = true;
                App.Log($"RecordingWatchdog: mic PCM stalled at {currentSize} bytes");
            }
            else if (_stalledFired)
            {
                _stalledFired = false;
                fireResumed = true;
                App.Log($"RecordingWatchdog: mic PCM resumed growing ({currentSize} bytes)");
            }
        }

        // Raised outside the lock: handlers hop to the UI thread and must not be
        // able to deadlock against a concurrent Stop().
        if (fireStalled) Stalled?.Invoke(this, EventArgs.Empty);
        if (fireResumed) Resumed?.Invoke(this, EventArgs.Empty);
    }

    private static long FileSizeOrZero(string path)
    {
        var info = new FileInfo(path);
        return info.Exists ? info.Length : 0;
    }

    /// <summary>
    /// Newest mic sidecar in the session directory, preferring the <c>_mic</c>
    /// naming the capture uses (<c>*_mic.pcm</c> / <c>*_mic.enc.pcm</c>, see
    /// <see cref="RecordingDirectoryScanner"/>) and falling back to the newest
    /// PCM of any kind.
    /// </summary>
    private string? FindLatestMicPcmFile()
    {
        if (!Directory.Exists(_recordingsDirectory)) return null;

        var pcmFiles = Directory.EnumerateFiles(_recordingsDirectory, "*.pcm")
            .OrderByDescending(File.GetCreationTimeUtc)
            .ToArray();

        var micFile = pcmFiles.FirstOrDefault(f =>
            Path.GetFileName(f).Contains("_mic", StringComparison.OrdinalIgnoreCase));

        return micFile ?? pcmFiles.FirstOrDefault();
    }

    public void Dispose() => Stop();
}
