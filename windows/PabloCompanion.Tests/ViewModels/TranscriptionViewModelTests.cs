using System.Security.Cryptography;
using AudioCapture.Models;
using PabloCompanion.Core;
using PabloCompanion.Models;
using PabloCompanion.Services;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Tests.ViewModels;

/// <summary>
/// Covers the cloud-only transcription flow on Windows (parity with the
/// macOS <c>TranscriptionViewModel</c>):
///   * happy-path audio upload clears the pending queue
///   * upload failure enqueues the session for retry
///   * pending uploads survive sign-out / sign-in via a fresh VM instance
///
/// Shares <see cref="SessionRecordingStore"/> with
/// <c>SessionRecordingStoreTests</c>, so the two are pinned to the same
/// collection to avoid the <c>Clear()</c>-in-teardown race.
/// </summary>
[Collection("SessionRecordingStore")]
public sealed class TranscriptionViewModelTests : IDisposable
{
    private readonly string _pendingPath = Path.Join(
        Path.GetTempPath(), $"pending-{Guid.NewGuid():N}.enc.json");
    private readonly string _audioPath = Path.Join(
        Path.GetTempPath(), $"audio-{Guid.NewGuid():N}.pcm");

    private readonly StubCredentialManager _credentials = new();
    private readonly SessionRecordingStore _recordingStore = new();

    public TranscriptionViewModelTests()
    {
        // Plaintext PCM sidecar — upload path streams the file as-is.
        File.WriteAllBytes(_audioPath, new byte[] { 0, 0, 0, 0 });
    }

    private PendingTranscriptionStore MakePendingStore() => new(_credentials, _pendingPath);

    private TranscriptionViewModel MakeVm(StubApiClient api, PendingTranscriptionStore store)
        => new(_recordingStore, store, api, _credentials);

    private void SeedRecording(string sessionId)
    {
        _recordingStore.Save(sessionId, new LocalRecording(
            Id: Guid.NewGuid(),
            FilePath: _audioPath,
            Duration: 1.0,
            CreatedAt: DateTime.UtcNow,
            IsEncrypted: false,
            Checksum: "test",
            ChannelLayout: ChannelLayout.SeparatedStereo,
            MicPcmFilePath: _audioPath,
            SystemPcmFilePath: null,
            IsUploaded: false));
    }

    [Fact]
    public async Task UploadAudioAsync_HappyPath_RemovesFromPendingAndMarksComplete()
    {
        SeedRecording("session-1");
        var api = new StubApiClient(_credentials) { FailNext = false };
        var store = MakePendingStore();
        var vm = MakeVm(api, store);

        await vm.UploadAudioAsync("session-1");

        Assert.Equal(1, api.CallCount);
        Assert.Equal("session-1", api.LastSessionId);
        Assert.Equal(TranscriptionState.Complete, vm.State);
        Assert.Null(store.Get("session-1"));
        Assert.Equal(0, vm.PendingUploadCount);
    }

    [Fact]
    public async Task UploadAudioAsync_Failure_LeavesEntryInPendingStore()
    {
        SeedRecording("session-2");
        var api = new StubApiClient(_credentials) { FailNext = true };
        var vm = MakeVm(api, MakePendingStore());

        await vm.UploadAudioAsync("session-2");

        Assert.Equal(TranscriptionState.PendingUpload, vm.State);
        var entry = MakePendingStore().Get("session-2");
        Assert.NotNull(entry);
        Assert.Equal(1, entry!.RetryCount);
    }

    /// <summary>
    /// Simulates a session that was enqueued but never got its first upload
    /// attempt in (e.g., app quit before the network call completed). After
    /// sign-out (recording store wiped) and sign-in (new VM instance), the
    /// encrypted pending blob is still on disk and
    /// <see cref="TranscriptionViewModel.ResumePendingUploadsAsync"/> picks
    /// it back up and uploads it.
    /// </summary>
    [Fact]
    public async Task ResumePendingUploadsAsync_RetriesAfterSignOutSignIn()
    {
        // Pre-sign-out: enqueue a session directly (never-attempted entry,
        // RetryCount=0, so ResumePendingUploadsAsync won't skip it on backoff).
        MakePendingStore().Add("session-3", _audioPath, null, isEncrypted: false);

        // Sign-out: AuthViewModel clears the recording store. Pending survives.
        _recordingStore.Clear();

        // Sign-in: fresh VM instance, backend now reachable.
        var api = new StubApiClient(_credentials) { FailNext = false };
        var vm = MakeVm(api, MakePendingStore());

        await vm.ResumePendingUploadsAsync();

        Assert.Equal(1, api.CallCount);
        Assert.Equal("session-3", api.LastSessionId);
        Assert.Null(MakePendingStore().Get("session-3"));
    }

    [Fact]
    public async Task ForceRetryPendingUploadsAsync_IgnoresBackoff()
    {
        SeedRecording("session-4");
        var api = new StubApiClient(_credentials) { FailNext = true };
        var vm = MakeVm(api, MakePendingStore());
        await vm.UploadAudioAsync("session-4");
        Assert.Equal(1, api.CallCount);

        // Even though the backoff window hasn't elapsed, Force retries immediately.
        api.FailNext = false;
        await vm.ForceRetryPendingUploadsAsync();

        Assert.Equal(2, api.CallCount);
        Assert.Null(MakePendingStore().Get("session-4"));
    }

    /// <summary>
    /// A dead server-side session (idle timeout) must not burn an upload
    /// attempt: the entry stays queued with no retry penalty, and the audio
    /// never leaves the disk until re-auth. The probe itself surfaces the
    /// re-auth flow via <c>UnauthenticatedDetected</c> inside APIClient.
    /// </summary>
    [Fact]
    public async Task UploadAudioAsync_WhenServerSessionDead_SkipsUploadAndKeepsEntryQueued()
    {
        SeedRecording("session-7");
        var api = new StubApiClient(_credentials) { SessionAlive = false };
        var vm = MakeVm(api, MakePendingStore());

        await vm.UploadAudioAsync("session-7");

        Assert.Equal(1, api.ProbeCallCount);
        Assert.Equal(0, api.CallCount);
        Assert.Equal(TranscriptionState.PendingUpload, vm.State);
        var entry = MakePendingStore().Get("session-7");
        Assert.NotNull(entry);
        Assert.Equal(0, entry!.RetryCount);
    }

    /// <summary>
    /// A failure inside the self-heal (e.g. the recovery PATCH itself fails) surfaces
    /// as an ordinary upload failure here: the entry stays queued and takes a retry.
    /// The heal's own mechanics are covered in <c>AudioUploadClientTests</c>.
    /// </summary>
    [Fact]
    public async Task UploadFromPendingAsync_WhenSelfHealFails_LeavesEntryForLaterRetry()
    {
        SeedRecording("session-5");
        var api = new StubApiClient(_credentials) { FailNext = true };
        var vm = MakeVm(api, MakePendingStore());

        await vm.UploadAudioAsync("session-5");

        Assert.Equal(1, api.CallCount);
        var entry = MakePendingStore().Get("session-5");
        Assert.NotNull(entry);
        Assert.Equal(1, entry!.RetryCount);
    }

    public void Dispose()
    {
        _recordingStore.Clear();
        TryDelete(_pendingPath);
        TryDelete(_audioPath);
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch (IOException) { /* best-effort cleanup */ }
        catch (UnauthorizedAccessException) { /* best-effort cleanup */ }
    }

    // --- stubs ---

    private sealed class StubCredentialManager : CredentialManager
    {
        private static readonly byte[] FixedKey = NewKey();
        private static byte[] NewKey() { var k = new byte[32]; RandomNumberGenerator.Fill(k); return k; }
        public override byte[]? GetOrCreateUserEncryptionKey() => FixedKey;
    }

    private sealed class StubApiClient : APIClient
    {
        public int CallCount { get; private set; }
        public string? LastSessionId { get; private set; }
        public bool FailNext { get; set; }

        // Session-liveness probe (server-side idle timeout). Defaults to alive
        // so the pre-upload probe never reaches the real network in tests.
        public bool SessionAlive { get; set; } = true;
        public int ProbeCallCount { get; private set; }

        public override Task<bool> VerifySessionAliveAsync()
        {
            ProbeCallCount++;
            return Task.FromResult(SessionAlive);
        }

        public StubApiClient(CredentialManager credentials) : base(credentials) { }

        /// <summary>
        /// The VM's upload seam. The INVALID_STATUS self-heal this wraps now lives
        /// below the APIClient boundary, in the core upload client, and is covered
        /// against the wire in <c>AudioUploadClientTests</c> — so from here it is a
        /// single call that either succeeds or throws.
        /// </summary>
        public override Task<AudioUploadResponse> UploadAudioWithSelfHealAsync(
            string sessionId, string therapistAudioPath, string? clientAudioPath = null)
        {
            CallCount++;
            LastSessionId = sessionId;
            if (FailNext)
                throw new InvalidOperationException("Simulated upload failure");
            return Task.FromResult(new AudioUploadResponse(
                Id: sessionId, Status: "recording_complete", Queue: "transcribe", Message: "ok"));
        }
    }
}
