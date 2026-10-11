using NAudio.CoreAudioApi;
using NAudio.Wave;
using PabloCompanion.Services;
using PabloCompanion.ViewModels;
using Xunit.Abstractions;

namespace PabloCompanion.Tests.Services;

/// <summary>
/// Runs only when <c>PABLO_REAL_AUDIO_CHECK=1</c>: it needs real audio devices,
/// which CI runners don't have.
/// </summary>
public sealed class RealAudioFactAttribute : FactAttribute
{
    public RealAudioFactAttribute()
    {
        if (Environment.GetEnvironmentVariable("PABLO_REAL_AUDIO_CHECK") != "1")
            Skip = "Needs real audio devices; set PABLO_REAL_AUDIO_CHECK=1 to run.";
    }
}

/// <summary>
/// The audio check end to end on this PC's real devices: the greeting plays on
/// the default output and the loopback has to hear it; then the default mic has
/// to hear a hello. With <c>PABLO_REAL_AUDIO_HELLO_WAV</c> set, that WAV is
/// played into the render device named by <c>PABLO_REAL_AUDIO_MIC_FEED</c>
/// (default "VB-Audio", a virtual cable whose output is the default mic);
/// otherwise someone at the PC says it.
/// </summary>
public class AudioCheckRealDeviceTests(ITestOutputHelper output)
{
    [RealAudioFact]
    public async Task HearsTheComputerAndTheMicOnRealDevices()
    {
        using (var enumerator = new MMDeviceEnumerator())
        {
            output.WriteLine($"default output: {enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Console).FriendlyName}");
            output.WriteLine($"default mic: {enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications).FriendlyName}");
        }

        var greeting = Path.Combine(AppContext.BaseDirectory, "Assets", "pablo-greeting.wav");
        if (!File.Exists(greeting)) greeting = GreetingPlayer.DefaultGreetingPath;
        Assert.True(File.Exists(greeting), $"greeting asset missing: {greeting}");

        var captures = new List<AudioCheckCapture>();
        var model = new AudioCheckViewModel(
            () =>
            {
                var capture = new AudioCheckCapture();
                captures.Add(capture);
                return capture;
            },
            new GreetingPlayer(greeting));

        var started = DateTimeOffset.UtcNow;
        Task? feeding = null;
        model.PropertyChanged += (_, e) =>
        {
            var at = (DateTimeOffset.UtcNow - started).TotalSeconds;
            switch (e.PropertyName)
            {
                case nameof(AudioCheckViewModel.Step):
                    output.WriteLine($"{at:F1}s step={model.Step}");
                    if (model.Step == AudioCheckStep.YourTurn) feeding = FeedHello();
                    break;
                case nameof(AudioCheckViewModel.HeardComputer) when model.HeardComputer:
                    output.WriteLine($"{at:F1}s heard computer");
                    break;
                case nameof(AudioCheckViewModel.HeardYou) when model.HeardYou:
                    output.WriteLine($"{at:F1}s heard you");
                    break;
            }
        };

        await model.RunAsync(micDeviceId: null).WaitAsync(TimeSpan.FromSeconds(60));
        if (feeding is not null) await feeding;

        output.WriteLine($"startFailure={model.StartFailure} heardComputer={model.HeardComputer} heardYou={model.HeardYou} passed={model.Passed}");
        Assert.Single(captures);
        Assert.False(Directory.Exists(captures[0].Directory), "temp folder deleted");
        Assert.True(model.Passed);
    }

    private Task FeedHello()
    {
        var wav = Environment.GetEnvironmentVariable("PABLO_REAL_AUDIO_HELLO_WAV");
        if (string.IsNullOrEmpty(wav)) return Task.CompletedTask;
        var target = Environment.GetEnvironmentVariable("PABLO_REAL_AUDIO_MIC_FEED") is { Length: > 0 } name ? name : "VB-Audio";
        return Task.Run(() =>
        {
            using var enumerator = new MMDeviceEnumerator();
            var device = enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active)
                .First(d => d.FriendlyName.Contains(target, StringComparison.OrdinalIgnoreCase));
            output.WriteLine($"feeding hello into {device.FriendlyName}");
            using var reader = new AudioFileReader(wav);
            using var player = new WasapiOut(device, AudioClientShareMode.Shared, true, 100);
            player.Init(reader);
            player.Play();
            var deadline = DateTime.UtcNow.AddSeconds(8);
            while (player.PlaybackState == PlaybackState.Playing && DateTime.UtcNow < deadline)
                Thread.Sleep(100);
        });
    }
}
