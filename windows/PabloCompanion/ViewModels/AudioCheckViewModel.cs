using CommunityToolkit.Mvvm.ComponentModel;
using PabloCompanion.Core;
using PabloCompanion.Helpers;
using PabloCompanion.Services;

namespace PabloCompanion.ViewModels;

/// <summary>Where "Say hello to Pablo" is.</summary>
public enum AudioCheckStep
{
    Intro,
    Greeting,
    YourTurn,
    Done,
}

/// <summary>Why capture couldn't start at all, if it couldn't.</summary>
public enum AudioCheckStartFailure
{
    None,
    MicrophonePermission,
    Other,
}

/// <summary>What the audio check says. Kept together so the dialog and tests read the same text.</summary>
public static class AudioCheckCopy
{
    public const string IntroTitle = "Let's make sure I can hear both sides of your sessions.";
    public const string IntroCaption = "This takes less than a minute.";
    public const string GreetingTitle = "Listen for Pablo...";
    public const string GreetingCaption =
        "\"Hi, I'm Pablo. Welcome to Pablo Companion! Now say, hello Pablo, so I can hear you.\"";
    public const string YourTurnTitle = "Your turn: say \"Hello, Pablo\"";
    public const string HeardComputer = "I can hear your computer. That's how I'll hear your client.";
    public const string HeardYou = "I can hear you.";
    public const string PassedTitle = "You're all set.";
    public const string PassedCaption = "Pablo's got it.";
    public const string NoComputerTitle = "I couldn't hear your computer";
    public const string NoComputerCaption =
        "Make sure your speakers or headset are on and Pablo's volume isn't muted in the volume mixer, then try again.";
    public const string NoYouTitle = "I couldn't hear you";
    public const string NoYouCaption =
        "Check that your microphone is connected and Pablo is allowed to use it, then try again.";
    public const string MicPermissionTitle = "Pablo needs your microphone";
    public const string MicPermissionCaption =
        "Turn on microphone access in Settings > Privacy & security > Microphone, then try again.";
    public const string StartFailedTitle = "Pablo couldn't start listening";
    public const string StartFailedCaption =
        "Check that your microphone and speakers are connected, then try again.";

    public const string DoItLater = "Do it later";
    public const string Start = "Start";
    public const string TryAgain = "Try again";
    public const string OpenSettings = "Open Settings";
    public const string Cancel = "Cancel";
    public const string Done = "Done";

    /// <summary>Settings > System > Sound > Volume mixer.</summary>
    public const string VolumeMixerUri = "ms-settings:apps-volume";
}

/// <summary>
/// Runs "Say hello to Pablo": Pablo greets the clinician through the speakers
/// (proving the loopback path a client's voice takes), then the clinician says
/// hello (proving the mic). Under a minute, nothing kept. Mirrors
/// <c>AudioCheckViewModel.swift</c>.
/// </summary>
public partial class AudioCheckViewModel : ObservableObject
{
    public static readonly TimeSpan GreetingTimeout = TimeSpan.FromSeconds(10);
    public static readonly TimeSpan HelloTimeout = TimeSpan.FromSeconds(8);

    /// <summary>How often levels are read while the check listens.</summary>
    internal static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(50);

    private readonly Func<IAudioCheckCapture> _captureFactory;
    private readonly IGreetingPlayer _player;
    private readonly TimeSpan _greetingTimeout;
    private readonly TimeSpan _helloTimeout;

    private AudioCheckEvaluator _evaluator = new();
    private IAudioCheckCapture? _capture;
    private CancellationTokenSource? _run;

    public AudioCheckViewModel()
        : this(() => new AudioCheckCapture(), new GreetingPlayer())
    {
    }

    internal AudioCheckViewModel(
        Func<IAudioCheckCapture> captureFactory,
        IGreetingPlayer player,
        TimeSpan? greetingTimeout = null,
        TimeSpan? helloTimeout = null)
    {
        _captureFactory = captureFactory;
        _player = player;
        _greetingTimeout = greetingTimeout ?? GreetingTimeout;
        _helloTimeout = helloTimeout ?? HelloTimeout;
    }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Passed))]
    public partial AudioCheckStep Step { get; private set; } = AudioCheckStep.Intro;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Passed))]
    public partial bool HeardComputer { get; private set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Passed))]
    public partial bool HeardYou { get; private set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Passed))]
    public partial AudioCheckStartFailure StartFailure { get; private set; }

    public bool Passed => HeardComputer && HeardYou && StartFailure == AudioCheckStartFailure.None;

    /// <summary>Runs the whole check, ending on <see cref="AudioCheckStep.Done"/>.</summary>
    public async Task RunAsync(string? micDeviceId)
    {
        _run?.Cancel();
        var run = new CancellationTokenSource();
        _run = run;
        var token = run.Token;

        await FinishCaptureAsync();
        Reset();
        Step = AudioCheckStep.Greeting;

        var capture = _captureFactory();
        _capture = capture;
        try
        {
            await capture.StartAsync(micDeviceId);
        }
        catch (Exception ex)
        {
            App.Log($"AudioCheck: capture did not start type={ex.GetType().Name}");
            StartFailure = RecordingStartFailure.IsAccessDenied(ex)
                ? AudioCheckStartFailure.MicrophonePermission
                : AudioCheckStartFailure.Other;
            await FinishAsync(run, capture);
            return;
        }

        using (var greeting = CancellationTokenSource.CreateLinkedTokenSource(token))
        {
            var playing = _player.PlayAsync(greeting.Token);
            await ListenUntilAsync(_greetingTimeout, () => playing.IsCompleted, token);
            greeting.Cancel();
            try { await playing; }
            catch (OperationCanceledException) { }
        }

        if (!token.IsCancellationRequested)
        {
            Step = AudioCheckStep.YourTurn;
            await ListenUntilAsync(_helloTimeout, () => HeardYou, token);
        }
        await FinishAsync(run, capture);
    }

    /// <summary>Stop early (window closed, Cancel). Cleans up like a normal finish.</summary>
    public async Task CancelAsync()
    {
        _run?.Cancel();
        await FinishCaptureAsync();
        if (Step is AudioCheckStep.Greeting or AudioCheckStep.YourTurn)
            Step = AudioCheckStep.Done;
    }

    private async Task ListenUntilAsync(TimeSpan timeout, Func<bool> condition, CancellationToken token)
    {
        var deadline = DateTimeOffset.UtcNow + timeout;
        while (!token.IsCancellationRequested)
        {
            Ingest();
            if (condition() || DateTimeOffset.UtcNow >= deadline) return;
            try
            {
                await Task.Delay(PollInterval, token);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    private void Ingest()
    {
        if (_capture is not { } capture) return;
        AudioCheckPhase phase;
        switch (Step)
        {
            case AudioCheckStep.Greeting: phase = AudioCheckPhase.Greeting; break;
            case AudioCheckStep.YourTurn: phase = AudioCheckPhase.YourTurn; break;
            default: return;
        }
        var levels = capture.CurrentLevels;
        _evaluator.Record(levels.MicLevel, levels.SystemLevel, phase, DateTimeOffset.UtcNow);
        HeardComputer = _evaluator.HeardComputer;
        HeardYou = _evaluator.HeardYou;
    }

    private async Task FinishAsync(CancellationTokenSource run, IAudioCheckCapture capture)
    {
        if (ReferenceEquals(_capture, capture)) _capture = null;
        await capture.FinishAsync();
        // A newer run (Try again) owns the step from here.
        if (ReferenceEquals(_run, run)) Step = AudioCheckStep.Done;
    }

    private async Task FinishCaptureAsync()
    {
        var capture = _capture;
        _capture = null;
        if (capture is not null) await capture.FinishAsync();
    }

    private void Reset()
    {
        _evaluator = new AudioCheckEvaluator();
        HeardComputer = false;
        HeardYou = false;
        StartFailure = AudioCheckStartFailure.None;
    }
}
