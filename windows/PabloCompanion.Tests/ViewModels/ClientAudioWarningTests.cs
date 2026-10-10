using PabloCompanion.Core;
using PabloCompanion.Helpers;
using PabloCompanion.Models;
using PabloCompanion.Services;
using PabloCompanion.Tests.Helpers;
using PabloCompanion.ViewModels;
using Xunit;

namespace PabloCompanion.Tests.ViewModels;

/// <summary>
/// How <see cref="RecordingViewModel"/> publishes the client audio status and
/// the "can't hear your client" warning, and what the indicator says.
/// </summary>
public class ClientAudioWarningTests
{
    private const float Speech = 0.05f;
    private static readonly DateTimeOffset Start = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);

    private static RecordingViewModel MakeRecordingVm() =>
        new(new RecordingService(new KeyCredentialManager(null)), new SessionRecordingStore())
        {
            State = RecordingUIState.Recording,
        };

    /// <summary>Ticks at 10 Hz for times in [from, to) seconds.</summary>
    private static void Tick(RecordingViewModel vm, int fromSeconds, int toSeconds, float mic, float system)
    {
        for (var t = fromSeconds * 10; t < toSeconds * 10; t++)
            vm.TrackClientAudio(mic, system, Start.AddTicks(t * TimeSpan.TicksPerSecond / 10));
    }

    [Fact]
    public void WarnsWhenTheClientCannotBeHeard()
    {
        var vm = MakeRecordingVm();
        Tick(vm, 0, 50, Speech, 0);

        Assert.Equal(ClientAudioStatus.NoClientAudio, vm.ClientAudioStatus);
        Assert.True(vm.ShowsClientAudioWarning);
    }

    [Fact]
    public void PublishesTheStatusOnlyWhenItChanges()
    {
        var vm = MakeRecordingVm();
        var changes = 0;
        vm.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(RecordingViewModel.ClientAudioStatus)) changes++;
        };

        Tick(vm, 0, 60, Speech, 0); // listening for 45 s, then no client audio

        Assert.Equal(1, changes);
    }

    [Fact]
    public void DismissingHidesTheWarningUntilTheStatusChanges()
    {
        var vm = MakeRecordingVm();
        Tick(vm, 0, 50, Speech, 0);
        vm.DismissClientAudioWarning();
        Assert.False(vm.ShowsClientAudioWarning);

        // Still no client: stays dismissed.
        Tick(vm, 50, 70, Speech, 0);
        Assert.False(vm.ShowsClientAudioWarning);

        // The client is heard, then lost again: warns again.
        Tick(vm, 70, 71, 0, Speech);
        Assert.Equal(ClientAudioStatus.HearingClient, vm.ClientAudioStatus);
        Tick(vm, 71, 200, Speech, 0);
        Assert.Equal(ClientAudioStatus.NoClientAudio, vm.ClientAudioStatus);
        Assert.True(vm.ShowsClientAudioWarning);
    }

    [Fact]
    public void ResumingStartsTheJudgementOver()
    {
        var vm = MakeRecordingVm();
        Tick(vm, 0, 50, Speech, 0);
        Assert.True(vm.ShowsClientAudioWarning);

        vm.PauseRecording();
        vm.ResumeRecording();

        Assert.Equal(ClientAudioStatus.Listening, vm.ClientAudioStatus);
        Assert.False(vm.ShowsClientAudioWarning);
        Tick(vm, 100, 140, Speech, 0); // 40 s after resuming: too early again
        Assert.Equal(ClientAudioStatus.Listening, vm.ClientAudioStatus);
    }

    [Fact]
    public void LevelsAreIgnoredWhilePaused()
    {
        var vm = MakeRecordingVm();
        vm.PauseRecording();
        Tick(vm, 0, 50, Speech, 0);

        Assert.Equal(ClientAudioStatus.Listening, vm.ClientAudioStatus);
    }

    [Theory]
    [InlineData(false, ClientAudioStatus.HearingClient, "Hearing client", ClientAudioTone.Good)]
    [InlineData(false, ClientAudioStatus.Listening, "Waiting for client audio", ClientAudioTone.Waiting)]
    [InlineData(false, ClientAudioStatus.NoClientAudio, "No client audio", ClientAudioTone.Problem)]
    [InlineData(true, ClientAudioStatus.HearingClient, "No system audio", ClientAudioTone.Problem)]
    [InlineData(true, ClientAudioStatus.Listening, "No system audio", ClientAudioTone.Problem)]
    public void TheIndicatorSaysWhatIsArriving(
        bool systemAudioInterrupted, ClientAudioStatus status, string label, ClientAudioTone tone)
    {
        var state = ClientAudioIndicatorState.For(systemAudioInterrupted, status);

        Assert.Equal(label, state.Label);
        Assert.Equal(tone, state.Tone);
    }
}
