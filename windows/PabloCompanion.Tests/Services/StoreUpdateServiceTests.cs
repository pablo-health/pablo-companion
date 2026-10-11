using PabloCompanion.Services;

namespace PabloCompanion.Tests.Services;

/// <summary>
/// The Store update schedule: a check at launch and every six hours while idle,
/// none while a session is recording or an upload is in flight, and an install
/// only when the user picks Restart.
/// </summary>
public class StoreUpdateServiceTests
{
    private sealed class FakeStore : IStoreUpdateClient
    {
        public int Checks;
        public int Installs;
        public StoreUpdateCheck Next = StoreUpdateCheck.NoUpdates;

        public Task<StoreUpdateCheck> CheckAsync()
        {
            Checks++;
            return Task.FromResult(Next);
        }

        public Task<bool> InstallAndRestartAsync()
        {
            Installs++;
            return Task.FromResult(true);
        }
    }

    private sealed class FakeClock
    {
        public DateTimeOffset Now = new(2026, 10, 10, 9, 0, 0, TimeSpan.Zero);
        public void Advance(TimeSpan by) => Now += by;
    }

    private static (StoreUpdateService Service, FakeStore Store, FakeClock Clock) Make(Func<bool> isBusy)
    {
        var store = new FakeStore();
        var clock = new FakeClock();
        var service = new StoreUpdateService(store, isBusy, () => clock.Now, StoreUpdateService.Interval);
        return (service, store, clock);
    }

    [Fact]
    public async Task ChecksAtLaunch_ThenEverySixHoursWhileIdle()
    {
        var (service, store, clock) = Make(() => false);

        await service.TickAsync();
        Assert.Equal(1, store.Checks);

        clock.Advance(TimeSpan.FromHours(5));
        await service.TickAsync();
        Assert.Equal(1, store.Checks);

        clock.Advance(TimeSpan.FromHours(1));
        await service.TickAsync();
        Assert.Equal(2, store.Checks);
    }

    [Fact]
    public async Task NeverChecksWhileBusy_AndChecksOnTheFirstIdleTickAfter()
    {
        var busy = true; // recording or uploading
        var (service, store, clock) = Make(() => busy);

        await service.TickAsync();
        clock.Advance(TimeSpan.FromHours(7));
        await service.TickAsync();
        Assert.Equal(0, store.Checks);

        busy = false;
        clock.Advance(TimeSpan.FromMinutes(1));
        await service.TickAsync();
        Assert.Equal(1, store.Checks);
    }

    [Fact]
    public async Task NeverInstallsWhileBusy()
    {
        var busy = false;
        var (service, store, _) = Make(() => busy);
        store.Next = StoreUpdateCheck.UpdateReady;
        var ready = 0;
        service.UpdateReady += (_, _) => ready++;

        await service.TickAsync();
        Assert.Equal(1, ready);
        Assert.True(service.IsUpdateReady);

        busy = true;
        Assert.False(await service.InstallAsync());
        Assert.Equal(0, store.Installs);

        busy = false;
        Assert.True(await service.InstallAsync());
        Assert.Equal(1, store.Installs);
    }

    [Fact]
    public async Task Later_OffersTheUpdateAgainOnTheNextScheduledCheck()
    {
        var (service, store, clock) = Make(() => false);
        store.Next = StoreUpdateCheck.UpdateReady;
        var ready = 0;
        service.UpdateReady += (_, _) => ready++;

        await service.TickAsync();
        service.Postpone();
        Assert.False(service.IsUpdateReady);

        clock.Advance(TimeSpan.FromHours(1));
        await service.TickAsync();
        Assert.Equal(1, ready);

        clock.Advance(TimeSpan.FromHours(6));
        await service.TickAsync();
        Assert.Equal(2, ready);
    }

    [Fact]
    public async Task NotAStoreInstall_StopsChecking()
    {
        var (service, store, clock) = Make(() => false);
        store.Next = StoreUpdateCheck.NotAvailable;

        await service.TickAsync();
        clock.Advance(TimeSpan.FromHours(12));
        await service.TickAsync();

        Assert.Equal(1, store.Checks);
        Assert.False(await service.InstallAsync());
    }

    [Fact]
    public async Task FailedCheck_RetriesOnSchedule()
    {
        var (service, store, clock) = Make(() => false);
        store.Next = StoreUpdateCheck.Failed;

        await service.TickAsync();
        clock.Advance(TimeSpan.FromHours(6));
        await service.TickAsync();

        Assert.Equal(2, store.Checks);
    }
}
