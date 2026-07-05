using PabloCompanion.Models;
using PabloCompanion.Services;

namespace PabloCompanion.Tests.Services;

/// <summary>
/// Covers the recording-time session heartbeat: Start probes liveness
/// immediately, ticks touch the session on the configured interval, failures
/// are swallowed (the recording must never be disturbed by a lost heartbeat),
/// and Stop halts the timer.
/// </summary>
public sealed class SessionKeepAliveServiceTests : IDisposable
{
    private readonly StubApiClient _api = new();
    private SessionKeepAliveService? _service;

    [Fact]
    public void Start_ProbesLivenessImmediately()
    {
        _service = new SessionKeepAliveService(_api, TimeSpan.FromHours(1));

        _service.Start();

        Assert.True(_service.IsRunning);
        Assert.Equal(1, _api.ProbeCallCount);
        Assert.Equal(0, _api.TouchCallCount); // first touch waits for the interval
    }

    [Fact]
    public void Start_WhileRunning_IsIdempotent()
    {
        _service = new SessionKeepAliveService(_api, TimeSpan.FromHours(1));

        _service.Start();
        _service.Start();

        Assert.Equal(1, _api.ProbeCallCount);
    }

    [Fact]
    public async Task Timer_TouchesSessionOnInterval()
    {
        _service = new SessionKeepAliveService(_api, TimeSpan.FromMilliseconds(20));

        _service.Start();
        await WaitUntilAsync(() => _api.TouchCallCount >= 1);

        Assert.True(_api.TouchCallCount >= 1);
    }

    [Fact]
    public async Task Stop_HaltsTouches()
    {
        _service = new SessionKeepAliveService(_api, TimeSpan.FromMilliseconds(20));
        _service.Start();
        await WaitUntilAsync(() => _api.TouchCallCount >= 1);

        _service.Stop();
        Assert.False(_service.IsRunning);
        var countAtStop = _api.TouchCallCount;
        await Task.Delay(100);

        Assert.Equal(countAtStop, _api.TouchCallCount);
    }

    [Fact]
    public async Task TickAsync_SwallowsTouchFailures()
    {
        _api.FailTouch = true;
        _service = new SessionKeepAliveService(_api, TimeSpan.FromHours(1));

        // Must not throw — a lost heartbeat waits for the next tick.
        await _service.TickAsync();

        Assert.Equal(1, _api.TouchCallCount);
    }

    private static async Task WaitUntilAsync(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (!condition() && DateTime.UtcNow < deadline)
        {
            await Task.Delay(10);
        }
    }

    public void Dispose() => _service?.Dispose();

    private sealed class StubApiClient : APIClient
    {
        private int _probeCallCount;
        private int _touchCallCount;

        public int ProbeCallCount => _probeCallCount;
        public int TouchCallCount => _touchCallCount;
        public bool FailTouch { get; set; }

        public StubApiClient() : base(new CredentialManager()) { }

        public override Task<bool> VerifySessionAliveAsync()
        {
            Interlocked.Increment(ref _probeCallCount);
            return Task.FromResult(true);
        }

        public override Task<SessionLiveness> TouchSessionAsync()
        {
            Interlocked.Increment(ref _touchCallCount);
            if (FailTouch)
                throw new PabloException(401, "Unauthenticated", APIClient.IdleTimeoutCode);
            return Task.FromResult(new SessionLiveness(
                Enforced: true, Active: true, SecondsRemaining: 900));
        }
    }
}
