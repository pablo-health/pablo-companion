using System.Security.Cryptography;
using AudioCapture.Models;
using PabloCompanion.Core;
using PabloCompanion.Models;
using PabloCompanion.Services;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Tests.ViewModels;

/// <summary>
/// Regression tests for <see cref="SessionViewModel.EndSessionAsync"/>. The
/// backend's <c>/upload-audio</c> route only accepts sessions in
/// <c>{recording_complete, transcribing, failed}</c>
/// (pablo/backend/app/routes/sessions.py:594-604), so the status PATCH MUST
/// happen before the upload. PR #68 inverted that order and every new upload
/// 400'd with <c>INVALID_STATUS</c> — these tests pin the correct order.
/// </summary>
[Collection("SessionRecordingStore")]
public sealed class SessionViewModelTests : IDisposable
{
    private readonly string _pendingPath = Path.Join(
        Path.GetTempPath(), $"pending-{Guid.NewGuid():N}.enc.json");
    private readonly string _audioPath = Path.Join(
        Path.GetTempPath(), $"audio-{Guid.NewGuid():N}.pcm");

    // Scoped away from the real recordings root: the upload path now deletes the
    // session directory on success, and these tests must not be able to name a
    // real one.
    private readonly string _recordingsRoot = Path.Join(
        Path.GetTempPath(), $"recordings-{Guid.NewGuid():N}");

    private readonly StubCredentialManager _credentials = new();
    private readonly SessionRecordingStore _recordingStore = new();

    public SessionViewModelTests()
    {
        File.WriteAllBytes(_audioPath, new byte[] { 0, 0, 0, 0 });
        Directory.CreateDirectory(_recordingsRoot);
    }

    private PendingTranscriptionStore MakePendingStore() => new(_credentials, _pendingPath);

    private (SessionViewModel session, StubApiClient api, PendingTranscriptionStore store)
        MakeSut()
    {
        var api = new StubApiClient(_credentials);
        var store = MakePendingStore();
        var transcriptionVm = new TranscriptionViewModel(
            _recordingStore, store, api, _credentials, new RecordingCleaner(_recordingsRoot));
        var recordingService = new RecordingService(_credentials);
        var recordingVm = new RecordingViewModel(recordingService, _recordingStore);
        var videoLaunch = new VideoLaunchService();
        var sessionVm = new SessionViewModel(api, videoLaunch, recordingVm, transcriptionVm);
        return (sessionVm, api, store);
    }

    private void SeedRecording(string sessionId)
    {
        _recordingStore.Save(sessionId, new LocalRecording(
            Id: Guid.NewGuid(), FilePath: _audioPath, Duration: 1.0,
            CreatedAt: DateTime.UtcNow, IsEncrypted: false, Checksum: "test",
            ChannelLayout: ChannelLayout.SeparatedStereo,
            MicPcmFilePath: _audioPath, SystemPcmFilePath: null,
            IsUploaded: false));
    }

    [Fact]
    public async Task EndSessionAsync_CallsUpdateStatusBeforeUploadAudio()
    {
        SeedRecording("session-A");
        var (sessionVm, api, _) = MakeSut();

        await sessionVm.EndSessionAsync("session-A");

        // Both calls happen; PATCH is sequenced before upload so the backend gate is satisfied.
        Assert.Equal(1, api.PatchCallCount);
        Assert.Equal(1, api.UploadCallCount);
        Assert.True(api.PatchOrder < api.UploadOrder,
            $"Expected PATCH (#{api.PatchOrder}) before upload (#{api.UploadOrder}).");
        Assert.Equal(SessionStatus.RecordingComplete, api.LastPatchStatus);
    }

    [Fact]
    public async Task EndSessionAsync_WhenStatusPatchFails_StillEnqueuesPendingUpload()
    {
        SeedRecording("session-B");
        var (sessionVm, api, _) = MakeSut();
        api.FailNextPatch = true;

        // Force upload to fail too — without that, the entry would be removed on
        // success and we couldn't observe the durable enqueue. The point of this
        // test is: even when both network calls fail, the audio path lands on
        // disk so a later ResumePendingUploadsAsync can heal the session.
        api.FailNextUpload = true;

        await sessionVm.EndSessionAsync("session-B");

        Assert.Equal(1, api.PatchCallCount);
        Assert.Equal(1, api.UploadCallCount);
        var entry = MakePendingStore().Get("session-B");
        Assert.NotNull(entry);
        Assert.Equal("session-B", entry!.SessionId);
    }

    public void Dispose()
    {
        _recordingStore.Clear();
        TryDelete(_pendingPath);
        TryDelete(_audioPath);
        try { if (Directory.Exists(_recordingsRoot)) Directory.Delete(_recordingsRoot, recursive: true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
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
        private int _callSequence;

        public int PatchCallCount { get; private set; }
        public int UploadCallCount { get; private set; }
        public SessionStatus? LastPatchStatus { get; private set; }
        public int PatchOrder { get; private set; } = int.MaxValue;
        public int UploadOrder { get; private set; } = int.MaxValue;

        public bool FailNextPatch { get; set; }
        public bool FailNextUpload { get; set; }

        public StubApiClient(CredentialManager credentials) : base(credentials) { }

        // Keep the pre-upload liveness probe off the real network in tests.
        public override Task<bool> VerifySessionAliveAsync() => Task.FromResult(true);

        public override Task<Session> UpdateSessionStatusAsync(string sessionId, SessionStatus status)
        {
            PatchCallCount++;
            PatchOrder = ++_callSequence;
            LastPatchStatus = status;
            if (FailNextPatch)
                throw new PabloException(500, "Simulated PATCH failure");
            return Task.FromResult(MakeSession(sessionId, status));
        }

        // The drain calls the self-healing entry point; the INVALID_STATUS heal it
        // wraps is covered against the wire in AudioUploadClientTests.
        public override Task<AudioUploadResponse> UploadAudioWithSelfHealAsync(
            string sessionId, string therapistAudioPath, string? clientAudioPath = null)
        {
            UploadCallCount++;
            UploadOrder = ++_callSequence;
            if (FailNextUpload)
                throw new InvalidOperationException("Simulated upload failure");
            return Task.FromResult(new AudioUploadResponse(
                Id: sessionId, Status: "recording_complete", Queue: "transcribe", Message: "ok"));
        }

        public override Task<Session[]> FetchTodaySessionsAsync(string timezone)
            => Task.FromResult(Array.Empty<Session>());

        private static Session MakeSession(string id, SessionStatus status) => new(
            Id: id, PatientId: null, Patient: null, Status: status,
            ScheduledAt: null, StartedAt: null, EndedAt: null,
            DurationMinutes: null, VideoLink: null, VideoPlatform: null,
            SessionType: null, Source: null, Notes: null,
            CreatedAt: null, UpdatedAt: null);
    }
}
