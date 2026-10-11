using AudioCapture.Capture;
using AudioCapture.Models;
using NAudio.Wave;
using PabloCompanion.Services;
using PabloCompanion.Tests.Helpers;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Tests.ViewModels;

/// <summary>Plays nothing; "finishes" after a set time, like a short greeting.</summary>
internal sealed class FakeGreetingPlayer(TimeSpan length) : IGreetingPlayer
{
    public int Plays { get; private set; }

    public async Task PlayAsync(CancellationToken cancellationToken)
    {
        Plays++;
        try { await Task.Delay(length, cancellationToken); }
        catch (OperationCanceledException) { }
    }
}

/// <summary>
/// The audio check over the real capture graph, with generated sources in
/// place of the WASAPI endpoints.
/// </summary>
public class AudioCheckViewModelTests
{
    /// <summary>
    /// A mic that is silent, then speaks for 0.6 s of every second: someone
    /// saying hello with pauses between words.
    /// </summary>
    private static SignalGeneratorWaveIn SpeakingMic() => new(
        new WaveFormat(48000, 16, 1),
        new SignalGeneratorWaveIn.MarkerTone(220, 440, MarkerPeriod: 1.0, MarkerOffset: 0.2, MarkerDuration: 0.6),
        baseAmplitude: 0f,
        markerAmplitude: 0.3f);

    private static SignalGeneratorWaveIn SilentMic() => new(
        new WaveFormat(48000, 16, 1),
        new SignalGeneratorWaveIn.MarkerTone(220, 440, 1.0),
        baseAmplitude: 0f,
        markerAmplitude: 0f);

    /// <summary>The greeting arriving on the loopback.</summary>
    private static SignalGeneratorWaveIn PlayingSystem() =>
        SignalGeneratorWaveIn.StereoFloat(new SignalGeneratorWaveIn.MarkerTone(300, 600, 1.0));

    private static SignalGeneratorWaveIn SilentSystem() => new(
        WaveFormat.CreateIeeeFloatWaveFormat(48000, 2),
        new SignalGeneratorWaveIn.MarkerTone(300, 600, 1.0),
        baseAmplitude: 0f,
        markerAmplitude: 0f);

    private sealed class Rig
    {
        public List<AudioCheckCapture> Captures { get; } = [];

        public AudioCheckViewModel Model(Func<IWaveIn> mic, Func<IWaveIn> system, TimeSpan? hello = null) =>
            new(
                () =>
                {
                    var capture = new AudioCheckCapture(() => new WasapiCaptureSession(mic, system));
                    Captures.Add(capture);
                    return capture;
                },
                new FakeGreetingPlayer(TimeSpan.FromMilliseconds(600)),
                greetingTimeout: TimeSpan.FromSeconds(5),
                helloTimeout: hello ?? TimeSpan.FromSeconds(8));
    }

    [Fact]
    public async Task ARunThatHearsBothSidesPassesAndLeavesNothingBehind()
    {
        var rig = new Rig();
        var model = rig.Model(SpeakingMic, PlayingSystem);
        var sawCaptureFolder = false;
        model.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(AudioCheckViewModel.Step) && model.Step == AudioCheckStep.YourTurn)
                sawCaptureFolder = Directory.Exists(rig.Captures[0].Directory);
        };

        await model.RunAsync(micDeviceId: null).WaitAsync(TimeSpan.FromSeconds(30));

        Assert.Equal(AudioCheckStep.Done, model.Step);
        Assert.Equal(AudioCheckStartFailure.None, model.StartFailure);
        Assert.True(model.HeardComputer);
        Assert.True(model.HeardYou);
        Assert.True(model.Passed);
        Assert.True(sawCaptureFolder, "the check records through the real capture graph into its temp folder");
        Assert.False(Directory.Exists(rig.Captures[0].Directory));
    }

    [Fact]
    public async Task ASilentLoopbackFailsTheComputerStepAndStillCleansUp()
    {
        var rig = new Rig();
        var model = rig.Model(SpeakingMic, SilentSystem);

        await model.RunAsync(micDeviceId: null).WaitAsync(TimeSpan.FromSeconds(30));

        Assert.Equal(AudioCheckStep.Done, model.Step);
        Assert.False(model.HeardComputer);
        Assert.True(model.HeardYou);
        Assert.False(model.Passed);
        Assert.False(Directory.Exists(rig.Captures[0].Directory));
    }

    [Fact]
    public async Task ASilentMicFailsTheHelloStepAfterItsTimeout()
    {
        var rig = new Rig();
        var model = rig.Model(SilentMic, PlayingSystem, hello: TimeSpan.FromSeconds(1.5));

        await model.RunAsync(micDeviceId: null).WaitAsync(TimeSpan.FromSeconds(30));

        Assert.True(model.HeardComputer);
        Assert.False(model.HeardYou);
        Assert.False(model.Passed);
        Assert.False(Directory.Exists(rig.Captures[0].Directory));
    }

    [Fact]
    public async Task ACaptureThatCannotStartReportsWhyAndCleansUp()
    {
        var rig = new Rig();
        var model = rig.Model(() => throw new UnauthorizedAccessException("denied"), PlayingSystem);

        await model.RunAsync(micDeviceId: null).WaitAsync(TimeSpan.FromSeconds(30));

        Assert.Equal(AudioCheckStep.Done, model.Step);
        Assert.Equal(AudioCheckStartFailure.MicrophonePermission, model.StartFailure);
        Assert.False(model.Passed);
        Assert.False(Directory.Exists(rig.Captures[0].Directory));
    }

    [Fact]
    public async Task CancellingMidRunStopsTheCaptureAndDeletesTheFolder()
    {
        var rig = new Rig();
        var model = rig.Model(SilentMic, PlayingSystem);

        var run = model.RunAsync(micDeviceId: null);
        await Eventually.TrueAsync(() => model.Step == AudioCheckStep.YourTurn, TimeSpan.FromSeconds(10), "the clinician's turn");
        await model.CancelAsync();
        await run.WaitAsync(TimeSpan.FromSeconds(10));

        Assert.Equal(AudioCheckStep.Done, model.Step);
        Assert.False(Directory.Exists(rig.Captures[0].Directory));
    }
}
