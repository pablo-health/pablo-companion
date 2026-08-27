using System.Security.Cryptography;
using System.Text;
using AudioCapture.Models;
using AudioCapture.Storage;
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
///   * local audio is deleted once — and only once — the backend confirms it
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
    private readonly string _recordingsRoot = Path.Join(
        Path.GetTempPath(), $"recordings-{Guid.NewGuid():N}");

    private readonly StubCredentialManager _credentials = new();
    private readonly SessionRecordingStore _recordingStore = new();

    public TranscriptionViewModelTests()
    {
        // Plaintext PCM sidecar — upload path streams the file as-is.
        File.WriteAllBytes(_audioPath, new byte[] { 0, 0, 0, 0 });
        Directory.CreateDirectory(_recordingsRoot);
    }

    private PendingTranscriptionStore MakePendingStore() => new(_credentials, _pendingPath);

    private TranscriptionViewModel MakeVm(
        StubApiClient api, PendingTranscriptionStore store, RecordingCleaner? cleaner = null)
        => new(_recordingStore, store, api, _credentials, cleaner ?? new RecordingCleaner(_recordingsRoot));

    /// <summary>
    /// Lays down a session exactly as the capture does — its own directory under
    /// the recordings root — so post-upload deletion has something real to remove.
    /// Returns the session directory.
    /// </summary>
    private string SeedRecording(string sessionId)
    {
        var sessionDir = Path.Join(_recordingsRoot, sessionId);
        Directory.CreateDirectory(sessionDir);
        var micPath = Path.Join(sessionDir, "rec_mic.pcm");
        File.WriteAllBytes(micPath, new byte[] { 0, 0, 0, 0 });

        _recordingStore.Save(sessionId, new LocalRecording(
            Id: Guid.NewGuid(),
            FilePath: micPath,
            Duration: 1.0,
            CreatedAt: DateTime.UtcNow,
            IsEncrypted: false,
            Checksum: "test",
            ChannelLayout: ChannelLayout.SeparatedStereo,
            MicPcmFilePath: micPath,
            SystemPcmFilePath: null,
            IsUploaded: false));

        return sessionDir;
    }

    /// <summary>
    /// Seeds a session that has already uploaded and is awaiting its note: the
    /// recording is on disk and the pending entry is in the AwaitingNote state.
    /// Returns the session directory so reconcile deletion can be asserted.
    /// </summary>
    private string SeedAwaitingNote(string sessionId, PendingTranscriptionStore store)
    {
        var sessionDir = SeedRecording(sessionId);
        store.Add(sessionId, Path.Join(sessionDir, "rec_mic.pcm"), null, isEncrypted: false);
        store.SetState(sessionId, UploadLifecycleState.AwaitingNote);
        return sessionDir;
    }

    /// <summary>
    /// A successful upload reports Complete but does NOT clear the queue: the
    /// entry moves to AwaitingNote and the audio is kept until the backend has
    /// actually produced the note (see the reconcile tests below). Acceptance is
    /// not completion.
    /// </summary>
    [Fact]
    public async Task UploadAudioAsync_HappyPath_MarksCompleteAndAwaitsNote()
    {
        SeedRecording("session-1");
        var api = new StubApiClient(_credentials) { FailNext = false };
        var store = MakePendingStore();
        var vm = MakeVm(api, store);

        await vm.UploadAudioAsync("session-1");

        Assert.Equal(1, api.CallCount);
        Assert.Equal("session-1", api.LastSessionId);
        Assert.Equal(TranscriptionState.Complete, vm.State);
        var entry = store.Get("session-1");
        Assert.NotNull(entry);
        Assert.Equal(UploadLifecycleState.AwaitingNote, entry!.State);
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
        // Uploaded, so it is no longer pending-upload — it is awaiting the note
        // (the stub's default status is mid-flight), not removed.
        var entry = MakePendingStore().Get("session-3");
        Assert.NotNull(entry);
        Assert.Equal(UploadLifecycleState.AwaitingNote, entry!.State);
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
        // The forced retry uploaded successfully, so the entry is now awaiting
        // the note rather than removed.
        var entry = MakePendingStore().Get("session-4");
        Assert.NotNull(entry);
        Assert.Equal(UploadLifecycleState.AwaitingNote, entry!.State);
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

    /// <summary>
    /// The 2xx from the upload is NOT the moment to delete: the backend can still
    /// fail to produce a note, and deleting on the ack once turned a transient
    /// backend race into permanent loss. The audio must survive the upload and
    /// only be removed once a note-status check confirms it — see the reconcile
    /// tests below.
    /// </summary>
    [Fact]
    public async Task UploadAudioAsync_OnSuccess_KeepsLocalRecordingUntilNoteExists()
    {
        var sessionDir = SeedRecording("session-8");
        var api = new StubApiClient(_credentials) { FailNext = false };
        var store = MakePendingStore();
        var vm = MakeVm(api, store);

        await vm.UploadAudioAsync("session-8");

        Assert.Equal(TranscriptionState.Complete, vm.State);
        Assert.True(Directory.Exists(sessionDir));
        Assert.Equal(UploadLifecycleState.AwaitingNote, store.Get("session-8")!.State);
    }

    /// <summary>
    /// The mirror case, and the one that loses a therapist's session if it's
    /// wrong: nothing is deleted until the backend has actually said yes. The
    /// audio has to still be there for the retry.
    /// </summary>
    [Fact]
    public async Task UploadAudioAsync_OnFailure_KeepsLocalRecordingDirectory()
    {
        var sessionDir = SeedRecording("session-9");
        var api = new StubApiClient(_credentials) { FailNext = true };
        var vm = MakeVm(api, MakePendingStore());

        await vm.UploadAudioAsync("session-9");

        Assert.Equal(TranscriptionState.PendingUpload, vm.State);
        Assert.True(Directory.Exists(sessionDir));
        Assert.True(File.Exists(Path.Join(sessionDir, "rec_mic.pcm")));
    }

    /// <summary>
    /// A dead server session never reaches the upload, so the audio must survive
    /// untouched for the post-re-auth retry.
    /// </summary>
    [Fact]
    public async Task UploadAudioAsync_WhenServerSessionDead_KeepsLocalRecordingDirectory()
    {
        var sessionDir = SeedRecording("session-10");
        var api = new StubApiClient(_credentials) { SessionAlive = false };
        var vm = MakeVm(api, MakePendingStore());

        await vm.UploadAudioAsync("session-10");

        Assert.True(Directory.Exists(sessionDir));
    }

    // --- Upload → note lifecycle (parity with macOS UploadLifecycleTests) ---
    //
    // These cover the fix for a real data-loss path: audio is kept until the
    // note exists, not deleted on the upload ack. A successful upload only moves
    // the entry to AwaitingNote; ReconcileAwaitingNotesAsync deletes it only once
    // the note is confirmed.

    /// <summary>Note ready (pending_review) → audio deleted, entry removed.</summary>
    [Fact]
    public async Task Reconcile_DeletesAudioOnceNoteExists()
    {
        var store = MakePendingStore();
        var sessionDir = SeedAwaitingNote("session-20", store);
        var api = new StubApiClient(_credentials) { NoteStatus = SessionStatus.PendingReview };
        var vm = MakeVm(api, store);

        var confirmed = await vm.ReconcileAwaitingNotesAsync();

        Assert.Equal(1, confirmed);
        Assert.Null(store.Get("session-20"));
        Assert.False(Directory.Exists(sessionDir));
    }

    /// <summary>A finalized note counts as ready too — both mapped statuses delete.</summary>
    [Fact]
    public async Task Reconcile_Finalized_AlsoDeletesAudio()
    {
        var store = MakePendingStore();
        var sessionDir = SeedAwaitingNote("session-21", store);
        var api = new StubApiClient(_credentials) { NoteStatus = SessionStatus.Finalized };
        var vm = MakeVm(api, store);

        var confirmed = await vm.ReconcileAwaitingNotesAsync();

        Assert.Equal(1, confirmed);
        Assert.Null(store.Get("session-21"));
        Assert.False(Directory.Exists(sessionDir));
    }

    /// <summary>
    /// The data-loss scenario, now safe: the backend failed, so the audio must
    /// survive and the upload must be re-queued — not deleted. The retry ladder
    /// resets because the upload itself had succeeded.
    /// </summary>
    [Fact]
    public async Task Reconcile_BackendFailure_ReQueuesUploadAndKeepsAudio()
    {
        var store = MakePendingStore();
        var sessionDir = SeedAwaitingNote("session-22", store);
        store.IncrementRetry("session-22"); // pretend it had retried
        var api = new StubApiClient(_credentials) { NoteStatus = SessionStatus.Failed };
        var vm = MakeVm(api, store);

        var confirmed = await vm.ReconcileAwaitingNotesAsync();

        Assert.Equal(0, confirmed);
        var entry = store.Get("session-22");
        Assert.NotNull(entry);
        Assert.Equal(UploadLifecycleState.PendingUpload, entry!.State); // back in the queue
        Assert.Equal(0, entry.RetryCount);                             // ladder reset
        Assert.True(Directory.Exists(sessionDir));                     // audio NOT deleted
    }

    /// <summary>Still transcribing → leave the entry and the audio alone.</summary>
    [Fact]
    public async Task Reconcile_StillTranscribing_LeavesEntryUntouched()
    {
        var store = MakePendingStore();
        var sessionDir = SeedAwaitingNote("session-23", store);
        var api = new StubApiClient(_credentials) { NoteStatus = SessionStatus.Transcribing };
        var vm = MakeVm(api, store);

        var confirmed = await vm.ReconcileAwaitingNotesAsync();

        Assert.Equal(0, confirmed);
        Assert.Equal(UploadLifecycleState.AwaitingNote, store.Get("session-23")!.State);
        Assert.True(Directory.Exists(sessionDir));
    }

    /// <summary>
    /// A network blip during the status check must not read as "no note" — that
    /// would delete the audio on a transient error. The entry stays AwaitingNote.
    /// </summary>
    [Fact]
    public async Task Reconcile_InconclusiveCheck_NeverDeletes()
    {
        var store = MakePendingStore();
        var sessionDir = SeedAwaitingNote("session-24", store);
        var api = new StubApiClient(_credentials) { FailStatusCheck = true };
        var vm = MakeVm(api, store);

        var confirmed = await vm.ReconcileAwaitingNotesAsync();

        Assert.Equal(0, confirmed);
        Assert.Equal(UploadLifecycleState.AwaitingNote, store.Get("session-24")!.State);
        Assert.True(Directory.Exists(sessionDir));
    }

    /// <summary>
    /// A delete that fails must not un-confirm a note that exists: the entry is
    /// still removed and the pass still succeeds — the leftover files are a
    /// disk-space problem, not a data-loss one.
    /// </summary>
    [Fact]
    public async Task Reconcile_WhenDeleteThrows_StillConfirmsNote()
    {
        var store = MakePendingStore();
        SeedAwaitingNote("session-25", store);
        var api = new StubApiClient(_credentials) { NoteStatus = SessionStatus.PendingReview };
        var vm = MakeVm(api, store, new ThrowingCleaner(_recordingsRoot));

        var confirmed = await vm.ReconcileAwaitingNotesAsync();

        Assert.Equal(1, confirmed);
        Assert.Null(store.Get("session-25"));
    }

    /// <summary>
    /// The upload drain must not re-upload an entry that has already uploaded and
    /// is only awaiting its note.
    /// </summary>
    [Fact]
    public async Task Resume_IgnoresAwaitingNoteEntries_DoesNotReupload()
    {
        var store = MakePendingStore();
        SeedAwaitingNote("session-26", store);
        var api = new StubApiClient(_credentials) { NoteStatus = SessionStatus.Transcribing };
        var vm = MakeVm(api, store);

        await vm.ResumePendingUploadsAsync();

        Assert.Equal(0, api.CallCount); // no upload attempt
    }

    /// <summary>
    /// A therapist can close the app mid-transcription; the AwaitingNote state
    /// must be on disk so the next launch resumes reconciliation rather than
    /// re-uploading or losing it.
    /// </summary>
    [Fact]
    public void AwaitingNoteState_SurvivesStoreReload()
    {
        MakePendingStore().Add("session-27", _audioPath, null, isEncrypted: false);
        MakePendingStore().SetState("session-27", UploadLifecycleState.AwaitingNote);

        // A fresh store instance reads the encrypted blob back from disk.
        var reopened = MakePendingStore().Get("session-27");

        Assert.NotNull(reopened);
        Assert.Equal(UploadLifecycleState.AwaitingNote, reopened!.State);
    }

    /// <summary>
    /// An entry written before the State field existed (no `state` in its JSON)
    /// must decode as PendingUpload — the old behaviour — not fail to deserialize
    /// and silently drop a queued upload.
    /// </summary>
    [Fact]
    public void LegacyEntryWithoutStateField_DecodesAsPendingUpload()
    {
        // Hand-write the encrypted blob exactly as a pre-State-field build would:
        // the entry's JSON has no "state" property at all. camelCase names match
        // the store's JsonNamingPolicy.
        const string legacyJson =
            """{"session-28":{"sessionId":"session-28","micPath":"/tmp/x.pcm","systemPath":null,"isEncrypted":false,"createdAt":"2026-01-01T00:00:00Z","retryCount":0}}""";
        var key = _credentials.GetOrCreateUserEncryptionKey()!;
        using (var enc = new AesGcmEncryptor(key, "device-key"))
        {
            File.WriteAllBytes(_pendingPath, enc.Encrypt(Encoding.UTF8.GetBytes(legacyJson)));
        }

        var entry = MakePendingStore().Get("session-28");

        Assert.NotNull(entry);
        Assert.Equal("session-28", entry!.SessionId);
        Assert.Equal(UploadLifecycleState.PendingUpload, entry.State);
    }

    public void Dispose()
    {
        _recordingStore.Clear();
        TryDelete(_pendingPath);
        TryDelete(_audioPath);
        try { if (Directory.Exists(_recordingsRoot)) Directory.Delete(_recordingsRoot, recursive: true); }
        catch (IOException) { /* best-effort cleanup */ }
        catch (UnauthorizedAccessException) { /* best-effort cleanup */ }
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch (IOException) { /* best-effort cleanup */ }
        catch (UnauthorizedAccessException) { /* best-effort cleanup */ }
    }

    // --- stubs ---

    /// <summary>
    /// Stands in for a cleaner that can't do its job — a sidecar still locked by
    /// another handle, say. The real one swallows its own failures; this proves
    /// the upload path doesn't rely on that.
    /// </summary>
    private sealed class ThrowingCleaner : RecordingCleaner
    {
        public ThrowingCleaner(string recordingsRoot) : base(recordingsRoot) { }

        public override bool DeleteSession(string sessionId)
            => throw new IOException("Simulated delete failure");
    }

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

        // Note-status check driven by reconcile. Defaults to a mid-flight status
        // (StillWorking) so a reconcile that runs incidentally leaves entries be.
        public SessionStatus NoteStatus { get; set; } = SessionStatus.Transcribing;
        public bool FailStatusCheck { get; set; }
        public int StatusCheckCount { get; private set; }

        public override Task<bool> VerifySessionAliveAsync()
        {
            ProbeCallCount++;
            return Task.FromResult(SessionAlive);
        }

        public override Task<Session> FetchSessionAsync(string sessionId)
        {
            StatusCheckCount++;
            if (FailStatusCheck)
                return Task.FromException<Session>(new InvalidOperationException("Simulated status check failure"));
            return Task.FromResult(new Session(
                Id: sessionId, PatientId: null, Patient: null, Status: NoteStatus,
                ScheduledAt: null, StartedAt: null, EndedAt: null, DurationMinutes: null,
                VideoLink: null, VideoPlatform: null, SessionType: null, Source: null,
                Notes: null, CreatedAt: null, UpdatedAt: null));
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
