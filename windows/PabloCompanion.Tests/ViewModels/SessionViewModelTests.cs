using System.Security.Cryptography;
using AudioCapture.Models;
using PabloCompanion.Core;
using PabloCompanion.Helpers;
using PabloCompanion.Tests.Helpers;
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
        var (sessionVm, api, store, _) = MakeSutWithTranscription();
        return (sessionVm, api, store);
    }

    private (SessionViewModel session, StubApiClient api, PendingTranscriptionStore store, TranscriptionViewModel transcription)
        MakeSutWithTranscription()
    {
        var api = new StubApiClient(_credentials);
        var store = MakePendingStore();
        var transcriptionVm = new TranscriptionViewModel(
            _recordingStore, store, api, _credentials, new RecordingCleaner(_recordingsRoot));
        var recordingService = new RecordingService(_credentials);
        var recordingVm = new RecordingViewModel(recordingService, _recordingStore);
        var videoLaunch = new VideoLaunchService();
        var sessionVm = new SessionViewModel(api, videoLaunch, recordingVm, transcriptionVm);
        return (sessionVm, api, store, transcriptionVm);
    }

    /// <summary>
    /// A SUT whose recording can never start: no encryption key, so the capture
    /// fails closed before touching any audio device.
    /// </summary>
    private (SessionViewModel session, StubApiClient api, RecordingViewModel recording) MakeSutWithoutKey()
    {
        var api = new StubApiClient(_credentials);
        var transcriptionVm = new TranscriptionViewModel(
            _recordingStore, MakePendingStore(), api, _credentials, new RecordingCleaner(_recordingsRoot));
        var recordingService = new RecordingService(new KeyCredentialManager(null));
        var recordingVm = new RecordingViewModel(recordingService, _recordingStore);
        var sessionVm = new SessionViewModel(api, new VideoLaunchService(), recordingVm, transcriptionVm);
        return (sessionVm, api, recordingVm);
    }

    private static Appointment MakeAppointment(string id, DateTimeOffset now) => new(
        Id: id,
        PatientId: "patient",
        Title: "Initial consultation",
        StartAt: now.AddMinutes(-5).ToString("o"),
        EndAt: now.AddMinutes(45).ToString("o"),
        DurationMinutes: 50,
        Status: "scheduled");

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

    [Fact]
    public async Task StartAppointmentSessionAsync_DoubleClickCreatesExactlyOneSession()
    {
        var (sessionVm, api, _) = MakeSut();
        api.HoldStartSession = new TaskCompletionSource<Session>(TaskCreationOptions.RunContinuationsAsynchronously);
        // The in-progress PATCH fails, so the start stops short of arming the mic:
        // this test is about the guard, not capture.
        api.FailNextPatch = true;

        var first = sessionVm.StartAppointmentSessionAsync("appointment-1");
        Assert.Equal("appointment-1", sessionVm.StartingAppointmentId);

        var second = await sessionVm.StartAppointmentSessionAsync("appointment-1");
        var otherAppointment = await sessionVm.StartAppointmentSessionAsync("appointment-2");

        api.HoldStartSession.SetResult(StubApiClient.MakeSession("session-1", SessionStatus.Scheduled));
        var firstResult = await first;

        Assert.True(firstResult.Ran);
        Assert.False(second.Ran);
        Assert.False(otherAppointment.Ran);
        Assert.Equal(1, api.StartSessionCallCount);
        Assert.Null(sessionVm.StartingAppointmentId);
    }

    [Fact]
    public async Task StartAppointmentSessionAsync_WhenCaptureDoesNotStart_ReleasesTheSessionAndOffersStartAgain()
    {
        var now = DateTimeOffset.UtcNow;
        var (sessionVm, api, recordingVm) = MakeSutWithoutKey();
        api.Appointments = [MakeAppointment("appointment-1", now)];
        await sessionVm.LoadTodayAppointmentsAsync();

        var outcome = await sessionVm.StartAppointmentSessionAsync("appointment-1");

        // A start whose capture didn't start is a failure, not a start, so the
        // asking panel (which waits on Recording) never opens for it.
        Assert.Equal(AppointmentStartKind.Failed, outcome.Kind);
        Assert.False(outcome.Recording);
        Assert.Equal("session-1", outcome.SessionId);

        // Nothing shows a recording that isn't happening...
        Assert.Null(recordingVm.ActiveSessionId);
        Assert.Equal(RecordingUIState.Idle, recordingVm.State);
        Assert.Null(recordingVm.Trouble);
        Assert.Null(sessionVm.ActiveSession);
        Assert.Equal(RecordingStartFailure.EncryptionUnavailableMessage, recordingVm.ErrorMessage);
        // ...the session marked in progress is put back to scheduled...
        Assert.Equal([SessionStatus.InProgress, SessionStatus.Scheduled], api.PatchStatuses);
        Assert.Equal("appointment-1", sessionVm.UnrecordedAppointmentId);

        // ...and the card offers Start again for the same appointment, not as
        // "recording on another device".
        var appointments = sessionVm.TodayAppointments;
        Assert.Equal("session-1", Assert.Single(appointments).SessionId);
        var card = MinimalShellSelection.SelectCard(
            appointments, now, recordingVm.ActiveSessionId, sessionVm.StartingAppointmentId,
            isLoading: false, hasError: false, unrecordedAppointmentId: sessionVm.UnrecordedAppointmentId);
        Assert.Equal(ShellCardKind.Appointment, card.Kind);
        Assert.Equal("appointment-1", card.Appointment?.Id);
        Assert.Equal(AppointmentAction.Start, card.Action);
        Assert.Null(MinimalShellSelection.InProgressElsewhere(
            appointments, now, recordingVm.ActiveSessionId, sessionVm.StartingAppointmentId, sessionVm.UnrecordedAppointmentId));

        // Start again reuses the appointment's session: the server allows one.
        var again = await sessionVm.StartAppointmentSessionAsync("appointment-1", askingConsentOnRecording: true);
        Assert.Equal(AppointmentStartKind.Failed, again.Kind);
        Assert.Equal("session-1", again.SessionId);
        Assert.Equal(1, api.StartSessionCallCount);
        Assert.Equal(
            [SessionStatus.InProgress, SessionStatus.Scheduled, SessionStatus.InProgress, SessionStatus.Scheduled],
            api.PatchStatuses);
        Assert.Equal("appointment-1", sessionVm.UnrecordedAppointmentId);
    }

    [Fact]
    public async Task StartAppointmentSessionAsync_WhenTheSessionDoesNotStart_SaysWhy()
    {
        var (sessionVm, api, recordingVm) = MakeSutWithoutKey();
        api.FailStartSession = true;

        var outcome = await sessionVm.StartAppointmentSessionAsync("appointment-1");

        Assert.Equal(AppointmentStartKind.Failed, outcome.Kind);
        Assert.Equal("Failed to start session from appointment.", sessionVm.StartErrorMessage);
        Assert.Null(recordingVm.ErrorMessage);
        Assert.Null(sessionVm.UnrecordedAppointmentId);
    }

    [Fact]
    public async Task StartAppointmentSessionAsync_ClearsTheGuardSoALaterStartRuns()
    {
        var (sessionVm, api, _) = MakeSut();
        api.FailStartSession = true;

        Assert.True((await sessionVm.StartAppointmentSessionAsync("appointment-1")).Ran);
        Assert.Null(sessionVm.StartingAppointmentId);
        Assert.True((await sessionVm.StartAppointmentSessionAsync("appointment-1")).Ran);
        Assert.Equal(2, api.StartSessionCallCount);
    }

    // --- Sessions this PC ended (never "Recording on another device") ---

    private static Appointment WithSession(Appointment appointment, string sessionId, string status) =>
        appointment with { SessionId = sessionId, SessionStatusRaw = status };

    /// <summary>
    /// Regression: after End Session the server keeps the session in progress
    /// until the upload finalizes, and the next refresh showed "Recording on
    /// another device" for the session this PC had just ended.
    /// </summary>
    [Fact]
    public async Task EndSession_ServerStillInProgress_IsNotRecordingOnAnotherDevice()
    {
        SeedRecording("session-1");
        var (sessionVm, api, _) = MakeSut();
        var now = DateTimeOffset.UtcNow;
        var mine = WithSession(MakeAppointment("mine", now), "session-1", "in_progress");
        api.Appointments = [mine];

        await sessionVm.EndSessionAndRefreshAsync("session-1");

        Assert.Contains("session-1", sessionVm.EndedHereSessionIds);
        Assert.Equal("session-1", sessionVm.LastEndedSessionId);
        Assert.Null(MinimalShellSelection.InProgressElsewhere(
            sessionVm.TodayAppointments, now, endedHereSessionIds: sessionVm.EndedHereSessionIds));
        var card = MinimalShellSelection.SelectCard(
            sessionVm.TodayAppointments, now, activeSessionId: null, startingAppointmentId: null,
            isLoading: false, hasError: false);
        Assert.NotEqual(ShellCardKind.Appointment, card.Kind);

        // A session genuinely recording elsewhere is still reported.
        var foreign = WithSession(MakeAppointment("foreign", now), "session-9", "in_progress");
        api.Appointments = [mine, foreign];
        await sessionVm.LoadTodayAppointmentsAsync();
        Assert.Equal("foreign", MinimalShellSelection.InProgressElsewhere(
            sessionVm.TodayAppointments, now, endedHereSessionIds: sessionVm.EndedHereSessionIds)?.Id);
    }

    [Fact]
    public async Task EndedHere_IsForgottenOnceTheServerNoLongerReportsItInProgress()
    {
        SeedRecording("session-1");
        var (sessionVm, api, _) = MakeSut();
        var now = DateTimeOffset.UtcNow;
        var mine = WithSession(MakeAppointment("mine", now), "session-1", "in_progress");
        api.Appointments = [mine];
        await sessionVm.EndSessionAndRefreshAsync("session-1");
        Assert.Contains("session-1", sessionVm.EndedHereSessionIds);

        api.Appointments = [mine with { SessionStatusRaw = "transcribing" }];
        await sessionVm.LoadTodayAppointmentsAsync();

        Assert.Empty(sessionVm.EndedHereSessionIds);
        // The card still follows its upload until the note exists.
        Assert.Equal("session-1", sessionVm.LastEndedSessionId);
    }

    [Fact]
    public async Task EndedHere_IsForgottenAfterThirtyMinutesEvenIfStillInProgress()
    {
        SeedRecording("session-1");
        var (sessionVm, api, _) = MakeSut();
        var start = DateTimeOffset.UtcNow;
        sessionVm.Clock = () => start;
        api.Appointments = [WithSession(MakeAppointment("mine", start), "session-1", "in_progress")];
        await sessionVm.EndSessionAndRefreshAsync("session-1");

        sessionVm.Clock = () => start + TimeSpan.FromMinutes(29);
        await sessionVm.LoadTodayAppointmentsAsync();
        Assert.Contains("session-1", sessionVm.EndedHereSessionIds);

        sessionVm.Clock = () => start + SessionViewModel.EndedSessionMemory + TimeSpan.FromSeconds(1);
        await sessionVm.LoadTodayAppointmentsAsync();
        Assert.Empty(sessionVm.EndedHereSessionIds);
    }

    [Fact]
    public async Task ClearAllData_ForgetsSessionsEndedHere()
    {
        SeedRecording("session-1");
        var (sessionVm, api, _) = MakeSut();
        api.Appointments = [WithSession(MakeAppointment("mine", DateTimeOffset.UtcNow), "session-1", "in_progress")];
        await sessionVm.EndSessionAndRefreshAsync("session-1");

        sessionVm.ClearAllData();

        Assert.Empty(sessionVm.EndedHereSessionIds);
        Assert.Null(sessionVm.LastEndedSessionId);
        Assert.Null(sessionVm.EndingSessionId);
    }

    // --- The card's upload status after End Session ---

    /// <summary>
    /// End Session -> "Uploading your session..." from the click (before the
    /// upload is even queued) and through the first attempt -> "Drafting your
    /// note..." once the server has the audio. Each phase change refreshes the
    /// appointments once, so the card catches up without waiting a minute.
    /// </summary>
    [Fact]
    public async Task EndSession_UploadingThenDraftingTheNote_RefreshesOnEachChange()
    {
        SeedRecording("session-1");
        var (sessionVm, api, _, transcriptionVm) = MakeSutWithTranscription();
        api.UploadGate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var fetchesAtStart = api.AppointmentFetchCount;

        var end = sessionVm.EndSessionAsync("session-1");
        await api.UploadStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Equal("session-1", sessionVm.EndingSessionId);
        Assert.Equal(SessionUploadPhase.Uploading, transcriptionVm.UploadPhase("session-1"));
        Assert.Equal(UploadStatusKind.Uploading, MinimalShellSelection.UploadStatus(
            transcriptionVm.UploadPhase("session-1"), ending: true, recordingOrStarting: false));
        var fetchesWhileUploading = api.AppointmentFetchCount;
        Assert.True(fetchesWhileUploading > fetchesAtStart, "Uploading should refresh the appointments once.");

        api.UploadGate.TrySetResult();
        await end.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Null(sessionVm.EndingSessionId);
        Assert.Equal(SessionUploadPhase.AwaitingNote, transcriptionVm.UploadPhase("session-1"));
        Assert.Equal(UploadStatusKind.DraftingNote, MinimalShellSelection.UploadStatus(
            transcriptionVm.UploadPhase("session-1"), ending: false, recordingOrStarting: false));
        Assert.True(api.AppointmentFetchCount > fetchesWhileUploading, "Drafting should refresh the appointments once.");
    }

    /// <summary>A failed first upload is the backlog note's, not the upload card's.</summary>
    [Fact]
    public async Task EndSession_FailedUpload_HandsOverToTheBacklogNote()
    {
        SeedRecording("session-1");
        var (sessionVm, api, _, transcriptionVm) = MakeSutWithTranscription();
        api.FailNextUpload = true;

        await sessionVm.EndSessionAsync("session-1");

        Assert.Equal(SessionUploadPhase.WaitingToRetry, transcriptionVm.UploadPhase("session-1"));
        Assert.Equal(UploadStatusKind.None, MinimalShellSelection.UploadStatus(
            transcriptionVm.UploadPhase("session-1"),
            ending: sessionVm.EndingSessionId == "session-1",
            recordingOrStarting: false));
        Assert.Equal(1, transcriptionVm.UploadBacklog.Waiting);
        Assert.True(transcriptionVm.UploadBacklog.HasFailed);
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
        public List<SessionStatus> PatchStatuses { get; } = [];
        public Appointment[] Appointments { get; set; } = [];
        public int UploadCallCount { get; private set; }
        public SessionStatus? LastPatchStatus { get; private set; }
        public int PatchOrder { get; private set; } = int.MaxValue;
        public int UploadOrder { get; private set; } = int.MaxValue;

        public bool FailNextPatch { get; set; }
        public bool FailNextUpload { get; set; }

        public int StartSessionCallCount { get; private set; }
        public bool FailStartSession { get; set; }
        public TaskCompletionSource<Session>? HoldStartSession { get; set; }

        public StubApiClient(CredentialManager credentials) : base(credentials) { }

        // Keep the pre-upload liveness probe off the real network in tests.
        public override Task<bool> VerifySessionAliveAsync() => Task.FromResult(true);

        public override Task<Session> UpdateSessionStatusAsync(string sessionId, SessionStatus status)
        {
            PatchCallCount++;
            PatchOrder = ++_callSequence;
            LastPatchStatus = status;
            PatchStatuses.Add(status);
            if (FailNextPatch)
                throw new PabloException(500, "Simulated PATCH failure");
            return Task.FromResult(MakeSession(sessionId, status));
        }

        // The drain calls the self-healing entry point; the INVALID_STATUS heal it
        // wraps is covered against the wire in AudioUploadClientTests.
        public override async Task<AudioUploadResponse> UploadAudioWithSelfHealAsync(
            string sessionId, string therapistAudioPath, string? clientAudioPath = null,
            Func<byte[], byte[]>? decryptChunk = null, int sampleRate = AudioUploadClient.DefaultSampleRate)
        {
            UploadCallCount++;
            UploadOrder = ++_callSequence;
            UploadStarted.TrySetResult();
            // A slow upload: holds until the test releases it, or 10 s.
            if (UploadGate is { } gate)
                await Task.WhenAny(gate.Task, Task.Delay(TimeSpan.FromSeconds(10)));
            if (FailNextUpload)
                throw new InvalidOperationException("Simulated upload failure");
            return new AudioUploadResponse(
                Id: sessionId, Status: "recording_complete", Queue: "transcribe", Message: "ok");
        }

        /// <summary>When set, the upload blocks until it completes (or 10 s pass).</summary>
        public TaskCompletionSource? UploadGate { get; set; }

        /// <summary>Completes once an upload has started.</summary>
        public TaskCompletionSource UploadStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public override Task<Session[]> FetchTodaySessionsAsync(string timezone)
            => Task.FromResult(Array.Empty<Session>());

        private int _appointmentFetchCount;
        public int AppointmentFetchCount => Volatile.Read(ref _appointmentFetchCount);

        public override Task<Appointment[]> FetchTodayAppointmentsAsync()
        {
            Interlocked.Increment(ref _appointmentFetchCount);
            return Task.FromResult(Appointments);
        }

        public override Task<Session> StartSessionFromAppointmentAsync(
            string appointmentId, bool askingConsentOnRecording = false)
        {
            StartSessionCallCount++;
            if (FailStartSession)
                throw new PabloException(500, "Simulated start failure");
            // The server links the new session to its appointment.
            Appointments = Appointments
                .Select(a => a.Id == appointmentId ? a with { SessionId = "session-1", SessionStatusRaw = "in_progress" } : a)
                .ToArray();
            return HoldStartSession?.Task ?? Task.FromResult(MakeSession("session-1", SessionStatus.Scheduled));
        }

        public static Session MakeSession(string id, SessionStatus status) => new(
            Id: id, PatientId: null, Patient: null, Status: status,
            ScheduledAt: null, StartedAt: null, EndedAt: null,
            DurationMinutes: null, VideoLink: null, VideoPlatform: null,
            SessionType: null, Source: null, Notes: null,
            CreatedAt: null, UpdatedAt: null);
    }
}
