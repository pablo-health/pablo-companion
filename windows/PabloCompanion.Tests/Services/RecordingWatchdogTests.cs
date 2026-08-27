using PabloCompanion.Services;

namespace PabloCompanion.Tests.Services;

/// <summary>
/// Covers stalled-capture detection: the first check only baselines, a sidecar
/// that stops growing raises Stalled exactly once, growth afterwards raises
/// Resumed, and nothing about a missing file or an unreadable directory is
/// allowed to throw into the recording.
///
/// The timer is driven directly via <c>Check()</c> (the seam
/// <c>SessionKeepAliveServiceTests</c> uses for <c>TickAsync</c>) so the
/// stall/resume logic is tested without waiting on real 60-second intervals or
/// a real WASAPI capture. Files are real: the directory scan and the size probe
/// are part of what's under test.
/// </summary>
public sealed class RecordingWatchdogTests : IDisposable
{
    private readonly string _dir = Path.Join(
        Path.GetTempPath(), $"watchdog-{Guid.NewGuid():N}");

    private RecordingWatchdog? _watchdog;
    private int _stalledCount;
    private int _resumedCount;

    public RecordingWatchdogTests()
    {
        Directory.CreateDirectory(_dir);
    }

    private RecordingWatchdog MakeWatchdog()
    {
        var watchdog = new RecordingWatchdog(
            _dir, TimeSpan.FromMilliseconds(10), TimeSpan.FromMilliseconds(10));
        watchdog.Stalled += (_, _) => Interlocked.Increment(ref _stalledCount);
        watchdog.Resumed += (_, _) => Interlocked.Increment(ref _resumedCount);
        _watchdog = watchdog;
        return watchdog;
    }

    /// <summary>Writes the mic sidecar at an exact size, as a growing capture would.</summary>
    private void WriteMicFile(long size, string name = "session_mic.pcm")
        => File.WriteAllBytes(Path.Join(_dir, name), new byte[size]);

    [Fact]
    public void Check_FirstCheck_OnlyBaselines()
    {
        WriteMicFile(100);
        var watchdog = MakeWatchdog();

        watchdog.Check();

        // One measurement can't distinguish a stall from a capture that just started.
        Assert.Equal(0, _stalledCount);
        Assert.False(watchdog.IsStalled);
    }

    [Fact]
    public void Check_WhenFileKeepsGrowing_NeverStalls()
    {
        WriteMicFile(100);
        var watchdog = MakeWatchdog();

        watchdog.Check();
        WriteMicFile(200);
        watchdog.Check();
        WriteMicFile(300);
        watchdog.Check();

        Assert.Equal(0, _stalledCount);
        Assert.False(watchdog.IsStalled);
    }

    [Fact]
    public void Check_WhenFileStopsGrowing_FiresStalled()
    {
        WriteMicFile(100);
        var watchdog = MakeWatchdog();

        watchdog.Check(); // baseline at 100
        watchdog.Check(); // still 100 — capture is dead

        Assert.Equal(1, _stalledCount);
        Assert.True(watchdog.IsStalled);
    }

    [Fact]
    public void Check_WhileAlreadyStalled_DoesNotRefire()
    {
        WriteMicFile(100);
        var watchdog = MakeWatchdog();

        watchdog.Check();
        watchdog.Check();
        watchdog.Check();
        watchdog.Check();

        Assert.Equal(1, _stalledCount);
    }

    [Fact]
    public void Check_WhenGrowthResumes_FiresResumed()
    {
        WriteMicFile(100);
        var watchdog = MakeWatchdog();

        watchdog.Check();
        watchdog.Check();
        Assert.True(watchdog.IsStalled);

        WriteMicFile(500);
        watchdog.Check();

        Assert.Equal(1, _resumedCount);
        Assert.False(watchdog.IsStalled);
    }

    [Fact]
    public void Check_StallAfterResume_FiresStalledAgain()
    {
        WriteMicFile(100);
        var watchdog = MakeWatchdog();

        watchdog.Check();
        watchdog.Check(); // stall #1
        WriteMicFile(500);
        watchdog.Check(); // resume
        watchdog.Check(); // stall #2 — still 500

        Assert.Equal(2, _stalledCount);
        Assert.Equal(1, _resumedCount);
        Assert.True(watchdog.IsStalled);
    }

    /// <summary>
    /// A capture that creates its sidecar and never writes a byte is the failure
    /// this watchdog exists for, so a file stuck at zero has to stall like any
    /// other. (macOS treats size 0 as "not baselined yet" and misses this.)
    /// </summary>
    [Fact]
    public void Check_WhenFileNeverGrowsFromZero_FiresStalled()
    {
        WriteMicFile(0);
        var watchdog = MakeWatchdog();

        watchdog.Check();
        watchdog.Check();

        Assert.Equal(1, _stalledCount);
    }

    [Fact]
    public void Check_WhenNoMicFileExists_DoesNotFire()
    {
        var watchdog = MakeWatchdog();

        watchdog.Check();
        watchdog.Check();

        Assert.Equal(0, _stalledCount);
        Assert.False(watchdog.IsStalled);
    }

    [Fact]
    public void Check_WhenDirectoryMissing_DoesNotThrow()
    {
        Directory.Delete(_dir, recursive: true);
        var watchdog = MakeWatchdog();

        watchdog.Check();
        watchdog.Check();

        Assert.Equal(0, _stalledCount);
    }

    /// <summary>
    /// The session directory also holds the system sidecar. Only the mic file
    /// tracks the therapist's own capture, so that is the one to monitor.
    /// </summary>
    [Fact]
    public void Check_PrefersMicSidecarOverOtherPcmFiles()
    {
        WriteMicFile(100, "session_system.pcm");
        WriteMicFile(100, "session_mic.pcm");
        var watchdog = MakeWatchdog();

        watchdog.Check();

        // System audio keeps flowing; the mic is dead. Must still stall.
        WriteMicFile(900, "session_system.pcm");
        watchdog.Check();

        Assert.Equal(1, _stalledCount);
    }

    [Fact]
    public void Check_FindsEncryptedMicSidecar()
    {
        WriteMicFile(100, "session_mic.enc.pcm");
        var watchdog = MakeWatchdog();

        watchdog.Check();
        watchdog.Check();

        Assert.Equal(1, _stalledCount);
    }

    [Fact]
    public void Stop_ClearsStallStateAndHaltsTimer()
    {
        WriteMicFile(100);
        var watchdog = MakeWatchdog();
        watchdog.Check();
        watchdog.Check();
        Assert.True(watchdog.IsStalled);

        watchdog.Stop();

        Assert.False(watchdog.IsStalled);
        Assert.False(watchdog.IsRunning);
    }

    /// <summary>
    /// Resuming from a pause re-baselines: the pause itself froze the file, and
    /// that must not be reported as a stall on the first check after resuming.
    /// </summary>
    [Fact]
    public void Start_AfterStall_ReBaselines()
    {
        WriteMicFile(100);
        var watchdog = MakeWatchdog();
        watchdog.Check();
        watchdog.Check();
        Assert.Equal(1, _stalledCount);

        watchdog.Stop();
        watchdog.Start();
        watchdog.Stop(); // don't let the real timer race the assertions

        Assert.False(watchdog.IsStalled);
    }

    [Fact]
    public async Task Timer_ChecksOnInterval()
    {
        WriteMicFile(100);
        var watchdog = MakeWatchdog();

        watchdog.Start();
        Assert.True(watchdog.IsRunning);

        // File never grows — the timer alone must get there.
        await WaitUntilAsync(() => Volatile.Read(ref _stalledCount) >= 1);

        Assert.True(Volatile.Read(ref _stalledCount) >= 1);
    }

    private static async Task WaitUntilAsync(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (!condition() && DateTime.UtcNow < deadline)
        {
            await Task.Delay(10);
        }
    }

    public void Dispose()
    {
        _watchdog?.Dispose();
        try { if (Directory.Exists(_dir)) Directory.Delete(_dir, recursive: true); }
        catch (IOException) { /* best-effort cleanup */ }
        catch (UnauthorizedAccessException) { /* best-effort cleanup */ }
    }
}
