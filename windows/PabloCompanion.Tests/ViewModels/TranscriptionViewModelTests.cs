using System.Security.Cryptography;
using AudioCapture.Models;
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
    /// Simulates the PR #68 fallout: a session got into PendingTranscriptionStore
    /// while its backend status was still "recording", so /upload-audio returns
    /// 400 INVALID_STATUS. The self-heal in UploadFromPendingAsync should PATCH
    /// status to recording_complete and retry the upload in the same pass.
    /// </summary>
    [Fact]
    public async Task UploadFromPendingAsync_OnInvalidStatus_PatchesThenRetriesUpload()
    {
        SeedRecording("session-5");
        var api = new StubApiClient(_credentials) { ThrowInvalidStatusOnNextUpload = true };
        var vm = MakeVm(api, MakePendingStore());

        await vm.UploadAudioAsync("session-5");

        // First upload throws INVALID_STATUS; PATCH runs; second upload succeeds.
        Assert.Equal(2, api.CallCount);
        Assert.Equal(1, api.PatchCallCount);
        Assert.Equal(SessionStatus.RecordingComplete, api.LastPatchStatus);
        Assert.Null(MakePendingStore().Get("session-5"));
    }

    [Fact]
    public async Task UploadFromPendingAsync_OnInvalidStatus_PatchFails_LeavesEntryForLaterRetry()
    {
        SeedRecording("session-6");
        var api = new StubApiClient(_credentials)
        {
            ThrowInvalidStatusOnNextUpload = true,
            FailNextPatch = true,
        };
        var vm = MakeVm(api, MakePendingStore());

        await vm.UploadAudioAsync("session-6");

        Assert.Equal(1, api.CallCount);   // upload only once — heal aborted at PATCH
        Assert.Equal(1, api.PatchCallCount);
        var entry = MakePendingStore().Get("session-6");
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

        // INVALID_STATUS self-heal path
        public bool ThrowInvalidStatusOnNextUpload { get; set; }
        public int PatchCallCount { get; private set; }
        public SessionStatus? LastPatchStatus { get; private set; }
        public bool FailNextPatch { get; set; }

        public StubApiClient(CredentialManager credentials) : base(credentials) { }

        public override Task<AudioUploadResponse> UploadAudioAsync(
            string sessionId, string therapistAudioPath, string? clientAudioPath = null)
        {
            CallCount++;
            LastSessionId = sessionId;
            if (ThrowInvalidStatusOnNextUpload)
            {
                ThrowInvalidStatusOnNextUpload = false;
                throw new PabloException(400, "Session must be in 'recording_complete'...", "INVALID_STATUS");
            }
            if (FailNext)
                throw new InvalidOperationException("Simulated upload failure");
            return Task.FromResult(new AudioUploadResponse(
                Id: sessionId, Status: "recording_complete", Queue: "transcribe", Message: "ok"));
        }

        public override Task<Session> UpdateSessionStatusAsync(string sessionId, SessionStatus status)
        {
            PatchCallCount++;
            LastPatchStatus = status;
            if (FailNextPatch)
                throw new PabloException(500, "Simulated PATCH failure");
            return Task.FromResult(MakeSession(sessionId, status));
        }

        private static Session MakeSession(string id, SessionStatus status) => new(
            Id: id, PatientId: null, Patient: null, Status: status,
            ScheduledAt: null, StartedAt: null, EndedAt: null,
            DurationMinutes: null, VideoLink: null, VideoPlatform: null,
            SessionType: null, Source: null, Notes: null,
            CreatedAt: null, UpdatedAt: null);
    }
}
