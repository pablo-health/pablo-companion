using PabloCompanion.Services;
using PabloCompanion.Tests.Helpers;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Tests.ViewModels;

internal sealed class FakeAudioCheckSettings : IAudioCheckSettings
{
    public bool Offered { get; set; }
}

/// <summary>The once-only, never-while-busy offer of "Say hello to Pablo".</summary>
public class AudioCheckFirstUseTests
{
    /// <summary>A settle delay the test releases by hand.</summary>
    private sealed class ManualDelay
    {
        private readonly List<(TaskCompletionSource Done, CancellationToken Token)> _waits = [];

        public TimeSpan? LastRequested { get; private set; }

        public int Pending => _waits.Count(w => !w.Done.Task.IsCompleted);

        public Task Delay(TimeSpan delay, CancellationToken token)
        {
            LastRequested = delay;
            var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            token.Register(() => done.TrySetCanceled(token));
            _waits.Add((done, token));
            return done.Task;
        }

        public void Elapse()
        {
            foreach (var (done, _) in _waits) done.TrySetResult();
        }
    }

    private static (AudioCheckFirstUse Offer, FakeAudioCheckSettings Settings, ManualDelay Delay, Func<int> Offers) Make()
    {
        var settings = new FakeAudioCheckSettings();
        var delay = new ManualDelay();
        var offer = new AudioCheckFirstUse(settings, delay.Delay);
        var count = 0;
        offer.OfferRequested += (_, _) => Interlocked.Increment(ref count);
        return (offer, settings, delay, () => Volatile.Read(ref count));
    }

    [Fact]
    public async Task OffersOnceASecondAfterTheWindowSettles()
    {
        var (offer, settings, delay, offers) = Make();

        offer.Update(isBusy: false);
        Assert.Equal(0, offers());
        Assert.Equal(TimeSpan.FromSeconds(1), delay.LastRequested);

        delay.Elapse();
        await Eventually.TrueAsync(() => offers() == 1, TimeSpan.FromSeconds(5), "the offer");
        Assert.True(settings.Offered);

        // The window refreshing, a recording starting and ending: never again.
        offer.Update(isBusy: false);
        offer.Update(isBusy: true);
        offer.Update(isBusy: false);
        delay.Elapse();
        await Task.Delay(100);
        Assert.Equal(1, offers());
        Assert.Equal(0, delay.Pending);
    }

    [Fact]
    public async Task IsNeverOfferedWhileRecording()
    {
        var (offer, settings, delay, offers) = Make();

        offer.Update(isBusy: true);
        delay.Elapse();
        await Task.Delay(100);

        Assert.Equal(0, offers());
        Assert.False(settings.Offered);
        Assert.Equal(0, delay.Pending);
    }

    [Fact]
    public async Task RecordingStartingDuringTheSettleCallsItOffUntilTheWindowIsFreeAgain()
    {
        var (offer, settings, delay, offers) = Make();

        offer.Update(isBusy: false);
        offer.Update(isBusy: true); // Start Session clicked within the second
        delay.Elapse();
        await Task.Delay(100);
        Assert.Equal(0, offers());
        Assert.False(settings.Offered);

        // The session ended: the window is free, so it is offered then.
        offer.Update(isBusy: false);
        delay.Elapse();
        await Eventually.TrueAsync(() => offers() == 1, TimeSpan.FromSeconds(5), "the offer after the session");
        Assert.True(settings.Offered);
    }

    [Fact]
    public async Task RepeatedUpdatesWhileSettlingStillOfferOnlyOnce()
    {
        var (offer, _, delay, offers) = Make();

        offer.Update(isBusy: false);
        offer.Update(isBusy: false);
        offer.Update(isBusy: false);
        delay.Elapse();
        await Eventually.TrueAsync(() => offers() == 1, TimeSpan.FromSeconds(5), "the offer");
        await Task.Delay(100);

        Assert.Equal(1, offers());
    }

    [Fact]
    public async Task AlreadyOfferedOnAnEarlierRunIsNotOfferedAgain()
    {
        var (offer, settings, delay, offers) = Make();
        settings.Offered = true;

        offer.Update(isBusy: false);
        delay.Elapse();
        await Task.Delay(100);

        Assert.Equal(0, offers());
        Assert.Null(delay.LastRequested);
    }

    [Fact]
    public void TheFileFallbackRemembersTheOfferAcrossInstances()
    {
        var marker = Path.Join(Path.GetTempPath(), $"pablo-audio-check-flag-{Guid.NewGuid():N}", "audio-check-offered");
        try
        {
            Assert.False(new AudioCheckSettings(packaged: false, marker).Offered);
            new AudioCheckSettings(packaged: false, marker).Offered = true;
            Assert.True(new AudioCheckSettings(packaged: false, marker).Offered);
        }
        finally
        {
            var dir = Path.GetDirectoryName(marker)!;
            if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true);
        }
    }
}
