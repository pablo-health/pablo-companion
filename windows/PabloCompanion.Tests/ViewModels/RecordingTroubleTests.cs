using System.Runtime.InteropServices;
using AudioCapture.Models;
using PabloCompanion.Helpers;
using PabloCompanion.Models;
using PabloCompanion.Services;
using PabloCompanion.Tests.Helpers;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Tests.ViewModels;

/// <summary>
/// The main window has to tell a therapist when a session's audio is being
/// lost: capture stalled, capture stopped, or audio that hasn't uploaded.
/// Ported from mac/PabloCompanionTests/RecordingTroubleTests.swift; keep the two
/// suites in step. The Mac drives its service callbacks by hand; here the real
/// <see cref="RecordingService"/> runs over injected sources, so the same events
/// arrive the way they do in the app.
/// </summary>
[Collection("SessionRecordingStore")]
public sealed class RecordingTroubleTests : IDisposable
{
    private static readonly TimeSpan OneSecond = TimeSpan.FromSeconds(1);

    private readonly CaptureRig _rig = new(KeyCredentialManager.NewKey());
    private readonly SessionRecordingStore _store = new();

    public void Dispose()
    {
        _store.Clear();
        _rig.Dispose();
    }

    private RecordingViewModel MakeViewModel() => new(_rig.Service, _store);

    private async Task<RecordingViewModel> RecordingSessionAsync()
    {
        var viewModel = MakeViewModel();
        Assert.True(await viewModel.StartRecordingForSessionAsync("session-1"));
        return viewModel;
    }

    private async Task DisconnectMicAsync(RecordingViewModel viewModel)
    {
        _rig.Mics[^1].Fail(new InvalidOperationException("device removed"));
        await Eventually.TrueAsync(() => viewModel.MicDisconnected, OneSecond, "the mic disconnect to reach the view model");
    }

    [Fact]
    public async Task AHealthyRecordingHasNoTrouble()
    {
        var viewModel = await RecordingSessionAsync();

        Assert.Equal(RecordingUIState.Recording, viewModel.State);
        Assert.Null(viewModel.Trouble);
        await viewModel.StopRecordingAsync();
    }

    [Fact]
    public async Task AStallFromTheWatchdogShowsAsStalled_AndClearsWhenAudioResumes()
    {
        _rig.Service.WatchdogTimings = (TimeSpan.FromMilliseconds(200), TimeSpan.FromMilliseconds(300));
        var viewModel = await RecordingSessionAsync();

        _rig.Mics[^1].Muted = true;
        await Eventually.TrueAsync(() => viewModel.Trouble == RecordingTrouble.Stalled, TimeSpan.FromSeconds(3), "a stall");
        Assert.Equal(RecordingTrouble.StalledMessage, viewModel.Trouble!.Message);

        _rig.Mics[^1].Muted = false;
        await Eventually.TrueAsync(() => viewModel.Trouble is null, TimeSpan.FromSeconds(3), "the stall to clear");
        await viewModel.StopRecordingAsync();
    }

    [Fact]
    public async Task AMicDisconnectShowsCaptureAsStoppedWithinASecond()
    {
        var viewModel = await RecordingSessionAsync();
        await Task.Delay(200);

        await DisconnectMicAsync(viewModel);

        Assert.Equal(RecordingTrouble.Stopped(RecordingTrouble.MicDisconnectedMessage), viewModel.Trouble);
        Assert.Equal(RecordingUIState.Idle, viewModel.State);
        // The session stays open for Restart Recording or End Session.
        Assert.Equal("session-1", viewModel.ActiveSessionId);
        // What was recorded before the mic went is kept for the upload.
        Assert.NotNull(_store.Get("session-1")?.MicPcmFilePath);
    }

    [Fact]
    public async Task AMicDisconnectDeviceEventShowsCaptureAsStoppedWithinASecond()
    {
        var viewModel = await RecordingSessionAsync();

        _rig.Sessions[^1].Delegate!.OnDeviceChanged(
            new CaptureDeviceChange(CaptureDeviceChangeKind.MicDisconnected, "{mic}", "device-state-changed"));

        await Eventually.TrueAsync(() => viewModel.MicDisconnected, OneSecond, "the device event to reach the view model");
        Assert.Equal(RecordingTrouble.Stopped(RecordingTrouble.MicDisconnectedMessage), viewModel.Trouble);
    }

    [Fact]
    public async Task AMicDisconnectTakesRecordingOffTheCard()
    {
        var viewModel = await RecordingSessionAsync();

        await DisconnectMicAsync(viewModel);

        Assert.Equal("Not recording", MinimalShellSelection.CaptureStateLabel(viewModel.State));
    }

    [Fact]
    public async Task AFailedCaptureTakesRecordingOffTheCard()
    {
        var viewModel = await RecordingSessionAsync();

        _rig.Sessions[^1].Delegate!.OnStateChanged(CaptureState.Failed(CaptureException.EncryptionFailed("disk full")));

        await Eventually.TrueAsync(() => viewModel.State == RecordingUIState.Idle, OneSecond, "the failure to stop the capture");
        Assert.Equal("Not recording", MinimalShellSelection.CaptureStateLabel(viewModel.State));
        Assert.NotNull(viewModel.Trouble);
    }

    [Fact]
    public async Task ACaptureFailureShowsCaptureAsStoppedWithItsReason()
    {
        var viewModel = await RecordingSessionAsync();

        _rig.Sessions[^1].Delegate!.OnStateChanged(CaptureState.Failed(CaptureException.Unknown("boom")));

        await Eventually.TrueAsync(() => viewModel.Trouble is not null, OneSecond, "the failure to show");
        Assert.Equal(RecordingTrouble.Stopped(RecordingTrouble.CaptureFailedMessage), viewModel.Trouble);
    }

    [Fact]
    public async Task AStartThatFailsLetsTheSessionGo()
    {
        _rig.Credentials.Key = null;
        var viewModel = MakeViewModel();

        var started = await viewModel.StartRecordingForSessionAsync("session-1");

        Assert.False(started);
        Assert.Null(viewModel.ActiveSessionId);
        Assert.Null(viewModel.Trouble);
        Assert.Equal(RecordingUIState.Idle, viewModel.State);
        Assert.Equal(RecordingStartFailure.EncryptionUnavailableMessage, viewModel.ErrorMessage);
        Assert.Equal("Recording didn't start because Pablo couldn't encrypt the audio on this PC.", viewModel.ErrorMessage);
        Assert.False(Directory.Exists(_rig.Root));
    }

    [Fact]
    public void TheMomentBeforeCaptureStartsIsNotTrouble()
    {
        // The session is open and capture hasn't started yet: idle, no reason.
        var viewModel = MakeViewModel();
        viewModel.ActiveSessionId = "session-1";

        Assert.Null(viewModel.Trouble);
    }

    [Fact]
    public async Task AStoppedCaptureWithNoOpenSessionIsNotTrouble()
    {
        var viewModel = await RecordingSessionAsync();
        await DisconnectMicAsync(viewModel);

        viewModel.ActiveSessionId = null;

        Assert.Null(viewModel.Trouble);
    }

    [Fact]
    public async Task RestartingClearsTheTrouble()
    {
        var viewModel = await RecordingSessionAsync();
        await DisconnectMicAsync(viewModel);

        await viewModel.RestartRecordingAsync();

        Assert.False(viewModel.MicDisconnected);
        Assert.Null(viewModel.Trouble);
        Assert.Equal(RecordingUIState.Recording, viewModel.State);
        Assert.Equal("session-1", viewModel.ActiveSessionId);
        await viewModel.StopRecordingAsync();
    }

    [Fact]
    public async Task ARestartThatFailsKeepsTheSessionAndShowsWhy()
    {
        var viewModel = await RecordingSessionAsync();
        await DisconnectMicAsync(viewModel);
        _rig.Credentials.Key = null;

        await viewModel.RestartRecordingAsync();

        Assert.Equal("session-1", viewModel.ActiveSessionId);
        Assert.Equal(RecordingTrouble.Stopped(RecordingStartFailure.EncryptionUnavailableMessage), viewModel.Trouble);
    }

    [Fact]
    public async Task EndingAStoppedSessionLetsItGo()
    {
        var viewModel = await RecordingSessionAsync();
        await DisconnectMicAsync(viewModel);

        await viewModel.StopRecordingAsync();

        Assert.Null(viewModel.ActiveSessionId);
        Assert.Null(viewModel.Trouble);
        Assert.NotNull(_store.Get("session-1"));
    }

    [Fact]
    public void TheCardLabelFollowsTheCaptureState()
    {
        Assert.Equal("Recording", MinimalShellSelection.CaptureStateLabel(RecordingUIState.Recording));
        Assert.Equal("Paused", MinimalShellSelection.CaptureStateLabel(RecordingUIState.Paused));
        Assert.Equal("Not recording", MinimalShellSelection.CaptureStateLabel(RecordingUIState.Idle));
    }

    // --- Every state x flag combination of the rule itself ---

    public static TheoryData<string?, RecordingUIState, bool, bool, string?, RecordingTrouble?> Combinations()
    {
        var data = new TheoryData<string?, RecordingUIState, bool, bool, string?, RecordingTrouble?>();
        var combinations =
            from session in new[] { null, "session-1" }
            from state in Enum.GetValues<RecordingUIState>()
            from stalled in new[] { false, true }
            from micDisconnected in new[] { false, true }
            from persistentError in new[] { null, "The capture failed." }
            select (session, state, stalled, micDisconnected, persistentError);
        foreach (var (session, state, stalled, micDisconnected, persistentError) in combinations)
        {
            RecordingTrouble? expected = (session, state) switch
            {
                (null, _) => null,
                (_, RecordingUIState.Idle) when micDisconnected => RecordingTrouble.Stopped(RecordingTrouble.MicDisconnectedMessage),
                (_, RecordingUIState.Idle) when persistentError is not null => RecordingTrouble.Stopped(persistentError),
                (_, RecordingUIState.Recording) when stalled => RecordingTrouble.Stalled,
                _ => null,
            };
            data.Add(session, state, stalled, micDisconnected, persistentError, expected);
        }
        return data;
    }

    [Theory]
    [MemberData(nameof(Combinations))]
    public void TroubleForEveryCombination(
        string? session, RecordingUIState state, bool stalled, bool micDisconnected, string? persistentError,
        RecordingTrouble? expected)
    {
        Assert.Equal(expected, RecordingTrouble.Evaluate(session, state, stalled, micDisconnected, persistentError));
    }

    [Fact]
    public void TheRuleSpelledOut()
    {
        // No open session: never trouble, whatever the flags say.
        Assert.Null(RecordingTrouble.Evaluate(null, RecordingUIState.Idle, true, true, "x"));
        // Idle without a reason is the moment before capture starts.
        Assert.Null(RecordingTrouble.Evaluate("s", RecordingUIState.Idle, false, false, null));
        // A stall only counts while recording; a paused capture is meant to be quiet.
        Assert.Null(RecordingTrouble.Evaluate("s", RecordingUIState.Paused, true, true, "x"));
        Assert.Null(RecordingTrouble.Evaluate("s", RecordingUIState.Idle, true, false, null));
        // The mic disconnect outranks another reason.
        Assert.Equal(RecordingTrouble.MicDisconnectedMessage,
            RecordingTrouble.Evaluate("s", RecordingUIState.Idle, false, true, "x")?.Message);
    }

    // --- Start failures ---

    [Fact]
    public void AnUnreadableKeyReadsAsEncryptionUnavailable()
    {
        var failure = RecordingStartFailure.Describe(new RecordingEncryptionUnavailableException());
        Assert.Equal("Recording didn't start because Pablo couldn't encrypt the audio on this PC.", failure.Message);
        Assert.False(failure.IsMicrophonePermission);
    }

    public static TheoryData<Exception> AccessDenied() => new()
    {
        new UnauthorizedAccessException(),
        new COMException("Access is denied.", unchecked((int)0x80070005)),
        CaptureException.PermissionDenied(),
        CaptureException.ConfigurationFailed("Access is denied. (0x80070005 (E_ACCESSDENIED))"),
        new InvalidOperationException("wrapped", new UnauthorizedAccessException()),
        new AggregateException(new UnauthorizedAccessException()),
    };

    [Theory]
    [MemberData(nameof(AccessDenied))]
    public void AMicrophoneWindowsRefusedReadsAsThePrivacySetting(Exception error)
    {
        var failure = RecordingStartFailure.Describe(error);

        Assert.True(failure.IsMicrophonePermission);
        Assert.Equal(
            "Pablo needs your microphone. Turn on microphone access in Settings > Privacy & security > Microphone, then start the session again.",
            failure.Message);
        Assert.Equal("ms-settings:privacy-microphone", RecordingStartFailure.MicrophoneSettingsUri);
    }

    [Fact]
    public void OtherFailuresAreNotAPermissionProblem()
    {
        Assert.False(RecordingStartFailure.Describe(CaptureException.DeviceNotAvailable()).IsMicrophonePermission);
        Assert.Equal(RecordingStartFailure.DeviceUnavailableMessage,
            RecordingStartFailure.Describe(CaptureException.DeviceNotAvailable()).Message);
        Assert.False(RecordingStartFailure.Describe(new IOException("disk")).IsMicrophonePermission);
    }
}

/// <summary>Ported from the Mac <c>UploadBacklogTests</c>.</summary>
public sealed class UploadBacklogTests
{
    private static PendingTranscription Entry(
        string sessionId,
        UploadLifecycleState state = UploadLifecycleState.PendingUpload,
        int retryCount = 0) =>
        new(sessionId, $"C:/rec/{sessionId}_mic.enc.pcm", null, true, DateTime.UtcNow, retryCount, state);

    [Fact]
    public void NothingQueuedShowsNothing()
    {
        var backlog = UploadBacklog.From([]);

        Assert.Equal(0, backlog.Waiting);
        Assert.Null(backlog.Message);
    }

    [Fact]
    public void AQueuedUploadIsWaiting()
    {
        var backlog = UploadBacklog.From([Entry("a")]);

        Assert.Equal(1, backlog.Waiting);
        Assert.False(backlog.HasFailed);
        Assert.Equal("Audio from 1 session hasn't uploaded yet.", backlog.Message);
    }

    [Fact]
    public void AFailedAttemptMarksTheBacklogFailed()
    {
        var backlog = UploadBacklog.From([Entry("a"), Entry("b", retryCount: 2)]);

        Assert.Equal(2, backlog.Waiting);
        Assert.True(backlog.HasFailed);
        Assert.Equal("Audio from 2 sessions hasn't uploaded yet.", backlog.Message);
    }

    [Fact]
    public void AudioAlreadyUploadedAndWaitingForItsNoteIsNotCounted()
    {
        var backlog = UploadBacklog.From([Entry("a", UploadLifecycleState.AwaitingNote, retryCount: 3)]);

        Assert.Equal(0, backlog.Waiting);
        Assert.False(backlog.HasFailed);
    }
}
