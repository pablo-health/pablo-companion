using AudioCapture.Storage;
using PabloCompanion.Models;
using PabloCompanion.Services;
using PabloCompanion.Tests.Helpers;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Tests.ViewModels;

/// <summary>
/// A sign-out that arrives while a session is recording (a 401 mid-session)
/// keeps the session's audio: capture ends cleanly and the audio is queued for
/// upload without a network call. And while capture runs, the PC is kept awake.
/// Ported from the macOS <c>stopAndQueueActiveRecording</c> behaviour.
/// </summary>
[Collection("SessionRecordingStore")]
public sealed class SignOutRecordingTests : IDisposable
{
    private static readonly TimeSpan OneSecond = TimeSpan.FromSeconds(1);

    private readonly CaptureRig _rig = new(KeyCredentialManager.NewKey());
    private readonly SessionRecordingStore _store = new();
    private readonly FakeSleepGuard _sleepGuard = new();
    private readonly string _pendingPath = Path.Join(Path.GetTempPath(), $"pending-{Guid.NewGuid():N}.enc.json");

    public void Dispose()
    {
        _store.Clear();
        try { if (File.Exists(_pendingPath)) File.Delete(_pendingPath); }
        catch (IOException) { }
        _rig.Dispose();
    }

    private RecordingViewModel MakeViewModel() => new(_rig.Service, _store, _sleepGuard);

    private PendingTranscriptionStore MakePendingStore() => new(_rig.Credentials, _pendingPath);

    private async Task<RecordingViewModel> RecordingSessionAsync()
    {
        var viewModel = MakeViewModel();
        Assert.True(await viewModel.StartRecordingForSessionAsync("session-1"));
        await Task.Delay(TimeSpan.FromSeconds(0.6));
        return viewModel;
    }

    private string MicSidecar => Path.Join(_rig.Service.SessionDirectory("session-1"), RecordingService.MicSidecarName);

    private string SystemSidecar => Path.Join(_rig.Service.SessionDirectory("session-1"), RecordingService.SystemSidecarName);

    private Func<byte[], byte[]> Decryptor()
    {
        var encryptor = new AesGcmEncryptor(_rig.Key!, "device-key");
        return encryptor.Decrypt;
    }

    [Fact]
    public async Task SignOutDuringARecording_QueuesTheSessionsSidecars_AndTheyDecrypt()
    {
        var viewModel = await RecordingSessionAsync();

        var queued = await viewModel.StopAndQueueAsync(MakePendingStore());
        viewModel.ClearAllData();

        Assert.Equal("session-1", queued);
        Assert.False(_rig.Service.IsRecording);
        Assert.Null(viewModel.ActiveSessionId);
        Assert.Equal(RecordingUIState.Idle, viewModel.State);

        // A fresh store reads what was persisted, as the next sign-in will.
        var entry = MakePendingStore().Get("session-1");
        Assert.NotNull(entry);
        Assert.Equal(MicSidecar, entry!.MicPath);
        Assert.Equal(SystemSidecar, entry.SystemPath);
        Assert.True(entry.IsEncrypted);
        Assert.Equal(UploadLifecycleState.PendingUpload, entry.State);
        Assert.Equal(0, entry.RetryCount);
        Assert.Equal(48000, entry.SampleRate);

        // Nothing on disk was deleted, and both sidecars decrypt.
        Assert.NotEmpty(SidecarStreamWriter.ReadEncrypted(entry.MicPath, Decryptor()));
        Assert.NotEmpty(SidecarStreamWriter.ReadEncrypted(entry.SystemPath!, Decryptor()));
    }

    [Fact]
    public async Task SignOutAfterTheCaptureStoppedOnItsOwn_StillQueuesWhatWasRecorded()
    {
        var viewModel = await RecordingSessionAsync();
        _rig.Mics[^1].Fail(new InvalidOperationException("device removed"));
        await Eventually.TrueAsync(() => viewModel.MicDisconnected, OneSecond, "the mic disconnect to reach the view model");

        var queued = await viewModel.StopAndQueueAsync(MakePendingStore());

        Assert.Equal("session-1", queued);
        var entry = MakePendingStore().Get("session-1")!;
        Assert.Equal(MicSidecar, entry.MicPath);
        Assert.NotEmpty(SidecarStreamWriter.ReadEncrypted(entry.MicPath, Decryptor()));
    }

    [Fact]
    public async Task SignOutWithNoSessionOpen_QueuesNothing()
    {
        var viewModel = MakeViewModel();

        Assert.Null(await viewModel.StopAndQueueAsync(MakePendingStore()));
        Assert.Empty(MakePendingStore().GetAll());
    }

    [Fact]
    public async Task ClearingDataNeverEndsALiveCapture()
    {
        var viewModel = await RecordingSessionAsync();

        viewModel.ClearAllData();

        // The capture keeps writing; only a stop ends it.
        Assert.True(_rig.Service.IsRecording);
        Assert.True(_sleepGuard.IsKeepingAwake);
        var recording = await _rig.Service.StopAsync();
        Assert.NotEmpty(SidecarStreamWriter.ReadEncrypted(recording.MicPcmFilePath!, Decryptor()));
    }

    // --- Keeping the PC awake ---

    [Fact]
    public async Task ThePcIsKeptAwakeWhileRecording_AndFreedByEndSession()
    {
        var viewModel = await RecordingSessionAsync();
        Assert.True(_sleepGuard.IsKeepingAwake);

        await viewModel.StopRecordingAsync();

        Assert.False(_sleepGuard.IsKeepingAwake);
    }

    [Fact]
    public async Task ACaptureThatStopsOnItsOwnFreesThePc()
    {
        var viewModel = await RecordingSessionAsync();

        _rig.Mics[^1].Fail(new InvalidOperationException("device removed"));
        await Eventually.TrueAsync(() => viewModel.MicDisconnected, OneSecond, "the mic disconnect to reach the view model");

        Assert.False(_sleepGuard.IsKeepingAwake);
        // The session is still open for Restart Recording; ending it changes nothing.
        await viewModel.StopRecordingAsync();
        Assert.False(_sleepGuard.IsKeepingAwake);
    }

    [Fact]
    public async Task ACaptureFailureFreesThePc()
    {
        var viewModel = await RecordingSessionAsync();

        _rig.Sessions[^1].Delegate!.OnStateChanged(AudioCapture.Models.CaptureState.Failed(
            AudioCapture.Models.CaptureException.Unknown("boom")));
        await Eventually.TrueAsync(() => viewModel.Trouble is not null, OneSecond, "the failure to show");

        Assert.False(_sleepGuard.IsKeepingAwake);
    }

    [Fact]
    public async Task SignOutDuringARecordingFreesThePc()
    {
        var viewModel = await RecordingSessionAsync();

        await viewModel.StopAndQueueAsync(MakePendingStore());
        viewModel.ClearAllData();

        Assert.False(_sleepGuard.IsKeepingAwake);
    }

    [Fact]
    public async Task ARestartKeepsThePcAwakeAgain_AndAFailedOneFreesIt()
    {
        var viewModel = await RecordingSessionAsync();
        _rig.Mics[^1].Fail(new InvalidOperationException("device removed"));
        await Eventually.TrueAsync(() => viewModel.MicDisconnected, OneSecond, "the mic disconnect to reach the view model");

        await viewModel.RestartRecordingAsync();
        Assert.Equal(RecordingUIState.Recording, viewModel.State);
        Assert.True(_sleepGuard.IsKeepingAwake);

        // Restart over a running capture: stop, append, held again.
        await viewModel.RestartRecordingAsync();
        Assert.True(_sleepGuard.IsKeepingAwake);

        _rig.Credentials.Key = null;
        await viewModel.RestartRecordingAsync();
        Assert.NotNull(viewModel.Trouble);
        Assert.False(_sleepGuard.IsKeepingAwake);
    }

    [Fact]
    public async Task AStartThatFailsNeverKeepsThePcAwake()
    {
        _rig.Credentials.Key = null;
        var viewModel = MakeViewModel();

        Assert.False(await viewModel.StartRecordingForSessionAsync("session-1"));

        Assert.False(_sleepGuard.IsKeepingAwake);
        Assert.Equal(0, _sleepGuard.KeepAwakeCalls);
    }

    [Fact]
    public async Task PausingKeepsThePcAwake()
    {
        var viewModel = await RecordingSessionAsync();

        viewModel.PauseRecording();
        Assert.True(_sleepGuard.IsKeepingAwake);

        viewModel.ResumeRecording();
        await viewModel.StopRecordingAsync();
        Assert.False(_sleepGuard.IsKeepingAwake);
    }

    /// <summary>Tracks the execution state the real guard would hold.</summary>
    private sealed class FakeSleepGuard : ISystemSleepGuard
    {
        private int _keepAwakeCalls;
        private volatile bool _keepingAwake;

        public bool IsKeepingAwake => _keepingAwake;

        public int KeepAwakeCalls => Volatile.Read(ref _keepAwakeCalls);

        public void KeepAwake()
        {
            Interlocked.Increment(ref _keepAwakeCalls);
            _keepingAwake = true;
        }

        public void AllowSleep() => _keepingAwake = false;
    }
}
