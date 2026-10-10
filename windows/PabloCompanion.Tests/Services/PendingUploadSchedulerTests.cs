using PabloCompanion.Services;

namespace PabloCompanion.Tests.Services;

/// <summary>
/// Covers the periodic drain + reconcile schedule: Start does NOT run a pass
/// immediately (launch already ran one), ticks run the pass on the configured
/// interval, a failing pass is swallowed so the schedule survives, and Stop
/// halts the timer.
/// </summary>
public sealed class PendingUploadSchedulerTests : IDisposable
{
    private PendingUploadScheduler? _scheduler;

    [Fact]
    public void Start_DoesNotRunPassImmediately()
    {
        var passes = 0;
        _scheduler = new PendingUploadScheduler(
            () => { Interlocked.Increment(ref passes); return Task.CompletedTask; },
            TimeSpan.FromHours(1));

        _scheduler.Start();

        Assert.True(_scheduler.IsRunning);
        // Launch already ran an immediate pass; the timer waits a full interval.
        Assert.Equal(0, passes);
    }

    [Fact]
    public void Start_WhileRunning_IsIdempotent()
    {
        _scheduler = new PendingUploadScheduler(() => Task.CompletedTask, TimeSpan.FromHours(1));

        _scheduler.Start();
        _scheduler.Start();

        Assert.True(_scheduler.IsRunning);
    }

    [Fact]
    public async Task Timer_RunsPassOnInterval()
    {
        var passes = 0;
        _scheduler = new PendingUploadScheduler(
            () => { Interlocked.Increment(ref passes); return Task.CompletedTask; },
            TimeSpan.FromMilliseconds(20));

        _scheduler.Start();
        await WaitUntilAsync(() => passes >= 1);

        Assert.True(passes >= 1);
    }

    [Fact]
    public async Task Stop_HaltsPasses()
    {
        var passes = 0;
        _scheduler = new PendingUploadScheduler(
            () => { Interlocked.Increment(ref passes); return Task.CompletedTask; },
            TimeSpan.FromMilliseconds(20));
        _scheduler.Start();
        await WaitUntilAsync(() => passes >= 1);

        _scheduler.Stop();
        Assert.False(_scheduler.IsRunning);
        var countAtStop = passes;
        await Task.Delay(100);

        Assert.Equal(countAtStop, passes);
    }

    [Fact]
    public async Task TickAsync_SwallowsPassFailures()
    {
        _scheduler = new PendingUploadScheduler(
            () => throw new InvalidOperationException("boom"),
            TimeSpan.FromHours(1));

        // Must not throw — a failed pass waits for the next tick.
        await _scheduler.TickAsync();
    }

    /// <summary>
    /// A tick that fires while the previous pass is still running (a long upload
    /// outlasting the interval) is skipped rather than starting a second pass.
    /// </summary>
    [Fact]
    public async Task OverlappingTicks_RunThePassOnce()
    {
        var passes = 0;
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _scheduler = new PendingUploadScheduler(
            async () => { Interlocked.Increment(ref passes); await release.Task; },
            TimeSpan.FromHours(1));

        var first = _scheduler.TickAsync();
        await _scheduler.TickAsync().WaitAsync(TimeSpan.FromSeconds(5));
        await _scheduler.TickAsync().WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Equal(1, passes);
        release.TrySetResult();
        await first;

        // Once the pass finishes, the next tick runs again.
        await _scheduler.TickAsync();
        Assert.Equal(2, passes);
    }

    private static async Task WaitUntilAsync(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (!condition() && DateTime.UtcNow < deadline)
        {
            await Task.Delay(10);
        }
    }

    public void Dispose() => _scheduler?.Dispose();
}
