using System.Security.Cryptography;
using AudioCapture.Models;
using PabloCompanion.Core;
using PabloCompanion.Models;
using PabloCompanion.Services;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Tests.ViewModels;

/// <summary>
/// The AI-notes consent flow around a session start: the prompt before arming,
/// the server's refusals turned into that prompt, the asking panel once
/// recording has started, and a decline on the recording deleting everything of
/// it. Ports macOS <c>RecordingConsentViewModelTests.swift</c> and
/// <c>DeclinedRecordingTests.swift</c>.
/// </summary>
[Collection("SessionRecordingStore")]
public sealed class RecordingConsentViewModelTests : IDisposable
{
    private const string SessionId = "session-1";

    private readonly string _pendingPath = Path.Join(Path.GetTempPath(), $"pending-{Guid.NewGuid():N}.enc.json");
    private readonly string _recordingsRoot = Path.Join(Path.GetTempPath(), $"recordings-{Guid.NewGuid():N}");
    private readonly StubCredentialManager _credentials = new();
    private readonly SessionRecordingStore _recordingStore = new();

    public RecordingConsentViewModelTests()
    {
        Directory.CreateDirectory(_recordingsRoot);
    }

    public void Dispose()
    {
        _recordingStore.Clear();
        try { if (File.Exists(_pendingPath)) File.Delete(_pendingPath); }
        catch (IOException) { }
        try { if (Directory.Exists(_recordingsRoot)) Directory.Delete(_recordingsRoot, recursive: true); }
        catch (IOException) { }
    }

    private sealed record Sut(
        RecordingConsentViewModel Consent,
        SessionViewModel Session,
        TranscriptionViewModel Transcription,
        ConsentStubApi Api,
        FakeRecorder Recorder,
        PendingTranscriptionStore Pending);

    private Sut MakeSut()
    {
        var api = new ConsentStubApi(_credentials);
        var pending = new PendingTranscriptionStore(_credentials, _pendingPath);
        var transcriptionVm = new TranscriptionViewModel(
            _recordingStore, pending, api, _credentials, new RecordingCleaner(_recordingsRoot));
        var recordingVm = new RecordingViewModel(new RecordingService(_credentials), _recordingStore);
        var recorder = new FakeRecorder();
        var sessionVm = new SessionViewModel(api, new VideoLaunchService(), recordingVm, transcriptionVm, recorder);
        var consentVm = new RecordingConsentViewModel(api, sessionVm, transcriptionVm);
        return new Sut(consentVm, sessionVm, transcriptionVm, api, recorder, pending);
    }

    private static RecordingConsentCheck Check(RecordingConsent consent, bool asks = true, int retention = 365,
        string? patientId = "pat-9") => new(consent, asks, retention, asks ? patientId : null);

    // --- before arming ---

    [Fact]
    public async Task SettingOff_StartIsOneClick_AndUnchanged()
    {
        var sut = MakeSut();
        sut.Api.Checks.Enqueue(() => Check(RecordingConsent.ClearValue, asks: false, retention: 30));

        await sut.Consent.RequestStartAsync("appt-1", "pat-9", AiConsentModality.InPerson);

        Assert.Equal([("appt-1", false)], sut.Api.Starts);
        Assert.Equal([SessionId], sut.Recorder.Started);
        Assert.Contains(SessionStatus.InProgress, sut.Api.Statuses);
        Assert.Equal(ConsentPromptKind.None, sut.Consent.Prompt);
        Assert.False(sut.Consent.IsAsking);
        Assert.Empty(sut.Api.Answers);
    }

    [Fact]
    public async Task ADeclinedClient_GetsTheDeclinedPrompt_AndNothingStarts()
    {
        var sut = MakeSut();
        sut.Api.Checks.Enqueue(() => Check(new RecordingConsent.Declined("2026-09-01")));

        await sut.Consent.RequestStartAsync("appt-1", "pat-9", AiConsentModality.InPerson);

        Assert.Equal(ConsentPromptKind.Declined, sut.Consent.Prompt);
        Assert.StartsWith("This client declined AI-assisted notes on ", sut.Consent.DeclinedMessage);
        Assert.Equal("pat-9", sut.Consent.PatientId);
        Assert.Empty(sut.Api.Starts);
        Assert.Empty(sut.Recorder.Started);
    }

    [Fact]
    public async Task InPersonWithNothingOnFile_StartRecordingAndAsk_AsksOnTheRecordingInPerson()
    {
        var sut = MakeSut();
        sut.Api.Checks.Enqueue(() => Check(new RecordingConsent.AskOnRecording(AiConsentModality.InPerson)));

        await sut.Consent.RequestStartAsync("appt-1", "pat-9", AiConsentModality.InPerson);
        Assert.Equal(ConsentPromptKind.AskOnRecording, sut.Consent.Prompt);
        Assert.Empty(sut.Api.Starts);

        await sut.Consent.StartAndAskAsync();

        Assert.Equal([("appt-1", true)], sut.Api.Starts);
        Assert.Equal(ConsentPromptKind.None, sut.Consent.Prompt);
        Assert.True(sut.Consent.IsAsking);
        Assert.Equal(SessionId, sut.Consent.AskSessionId);
        Assert.Equal("pat-9", sut.Consent.AskPatientId);
        Assert.False(sut.Consent.AsksLocation);
        Assert.Equal("The audio is kept for up to 1 year.", sut.Consent.ScriptLines[2]);
    }

    [Fact]
    public async Task StartRecordingAndAsk_WhenCaptureDoesNotStart_NeverOpensTheAskingPanel()
    {
        var sut = MakeSut();
        sut.Recorder.FailStart = true;
        sut.Api.Checks.Enqueue(() => Check(new RecordingConsent.AskOnRecording(AiConsentModality.InPerson)));

        await sut.Consent.RequestStartAsync("appt-1", "pat-9", AiConsentModality.InPerson);
        await sut.Consent.StartAndAskAsync();

        // The start told the server it is asking, then capture failed: the session
        // goes back to scheduled, the appointment stays startable, and nothing
        // asks on a recording that isn't running.
        Assert.Equal([("appt-1", true)], sut.Api.Starts);
        Assert.Equal([SessionStatus.InProgress, SessionStatus.Scheduled], sut.Api.Statuses);
        Assert.Equal("appt-1", sut.Session.UnrecordedAppointmentId);
        Assert.False(sut.Consent.IsAsking);
        Assert.Equal(ConsentPromptKind.None, sut.Consent.Prompt);
    }

    [Fact]
    public async Task DontRecord_WritesNothing()
    {
        var sut = MakeSut();
        sut.Api.Checks.Enqueue(() => Check(new RecordingConsent.AskOnRecording(AiConsentModality.Telehealth)));

        await sut.Consent.RequestStartAsync("appt-1", "pat-9", AiConsentModality.Telehealth);
        sut.Consent.DismissPrompt();

        Assert.Equal(ConsentPromptKind.None, sut.Consent.Prompt);
        Assert.Empty(sut.Api.Starts);
        Assert.Empty(sut.Api.Answers);
    }

    [Fact]
    public async Task AFailedRead_DoesNotBlock_ItReadsAsClearAndTheServerStillGates()
    {
        var sut = MakeSut();
        sut.Api.Checks.Enqueue(() => throw new ConsentRequestException(500, null));

        await sut.Consent.RequestStartAsync("appt-1", "pat-9", AiConsentModality.InPerson);

        Assert.Equal([("appt-1", false)], sut.Api.Starts);
        Assert.Equal(ConsentPromptKind.None, sut.Consent.Prompt);
    }

    [Fact]
    public async Task ASignOutDuringTheRead_StartsNothing()
    {
        var sut = MakeSut();
        sut.Api.HoldCheck = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        sut.Api.Checks.Enqueue(() => Check(RecordingConsent.ClearValue, asks: false));

        var start = sut.Consent.RequestStartAsync("appt-1", "pat-9", AiConsentModality.InPerson);
        Assert.True(sut.Consent.IsChecking);
        sut.Consent.ClearAllData();
        sut.Api.HoldCheck.SetResult();
        await start;

        Assert.Empty(sut.Api.Starts);
        Assert.Equal(ConsentPromptKind.None, sut.Consent.Prompt);
    }

    // --- web hand-off ---

    [Fact]
    public async Task ATelehealthHandOffWhoseWebStartChoseAskNow_StartsAskingAndGoesStraightToTheAskingPanel()
    {
        var sut = MakeSut();
        sut.Api.Checks.Enqueue(() => Check(new RecordingConsent.AskOnRecording(AiConsentModality.Telehealth), retention: 0));

        // Redeem: telehealth = true, ask_consent_on_recording = true.
        var consent = await sut.Consent.CheckHandoffAsync("appt-1", AiConsentModality.Telehealth,
            webAlreadyAsked: false, webAskingOnRecording: true);

        // No "Start recording and ask" offered again: the confirmation's Start
        // Recording is the one tap.
        Assert.Equal(new RecordingConsent.AskingOnRecording(AiConsentModality.Telehealth), consent);
        Assert.Equal(ConsentPromptKind.None, sut.Consent.Prompt);

        await sut.Consent.ConfirmHandoffAsync("appt-1");

        Assert.Equal([("appt-1", true)], sut.Api.Starts);
        Assert.True(sut.Consent.IsAsking);
        Assert.True(sut.Consent.AsksLocation);
        Assert.Equal("pat-9", sut.Consent.AskPatientId);
        Assert.Equal("I've started recording our session.", sut.Consent.ScriptLines[0]);
        Assert.Equal("The audio is deleted once your note is signed.", sut.Consent.ScriptLines[2]);
    }

    [Fact]
    public async Task AnInPersonHandOffTheWebAlreadyAskedAbout_ArmsWithoutAskingAgain()
    {
        var sut = MakeSut();
        sut.Api.Checks.Enqueue(() => Check(new RecordingConsent.AskOnRecording(AiConsentModality.InPerson)));

        var consent = await sut.Consent.CheckHandoffAsync("appt-1", AiConsentModality.InPerson,
            webAlreadyAsked: true, webAskingOnRecording: false);
        await sut.Consent.ConfirmHandoffAsync("appt-1");

        Assert.Equal(RecordingConsent.ClearValue, consent);
        Assert.Equal([("appt-1", false)], sut.Api.Starts);
        Assert.False(sut.Consent.IsAsking);
    }

    [Fact]
    public async Task AWebRecordAnyway_DoesNotClearATelehealthClientNobodyHasAsked()
    {
        var sut = MakeSut();
        sut.Api.Checks.Enqueue(() => Check(new RecordingConsent.AskOnRecording(AiConsentModality.Telehealth)));

        await sut.Consent.CheckHandoffAsync("appt-1", AiConsentModality.Telehealth,
            webAlreadyAsked: true, webAskingOnRecording: false);

        Assert.Equal(ConsentPromptKind.AskOnRecording, sut.Consent.Prompt);
        Assert.Empty(sut.Api.Starts);
    }

    // --- the server's refusals ---

    [Fact]
    public async Task A403ConsentNeeded_ReoffersStartRecordingAndAsk_NeverAGenericError()
    {
        var sut = MakeSut();
        // An older read said clear; the server knows better.
        sut.Api.Checks.Enqueue(() => Check(RecordingConsent.ClearValue));
        sut.Api.StartResults.Enqueue(() => throw new PabloException(403, "Forbidden", RecordingConsent.ConsentNeededErrorCode));
        sut.Api.Checks.Enqueue(() => Check(new RecordingConsent.AskOnRecording(AiConsentModality.Telehealth)));

        await sut.Consent.RequestStartAsync("appt-1", "pat-9", AiConsentModality.InPerson);

        Assert.Equal(ConsentPromptKind.AskOnRecording, sut.Consent.Prompt);
        Assert.Null(sut.Session.ErrorMessage);
        Assert.False(sut.Session.SubscriptionBlocked);
        Assert.Empty(sut.Recorder.Started);
        // Read again, telehealth, so the ask knows the client.
        Assert.Equal(AiConsentModality.Telehealth, sut.Api.CheckModalities[^1]);

        await sut.Consent.StartAndAskAsync();

        Assert.Equal([("appt-1", false), ("appt-1", true)], sut.Api.Starts);
        Assert.True(sut.Consent.IsAsking);
        Assert.True(sut.Consent.AsksLocation);
    }

    [Fact]
    public async Task A403ConsentNeeded_WithAFailedReRead_StillOffersStartRecordingAndAsk()
    {
        var sut = MakeSut();
        sut.Api.Checks.Enqueue(() => throw new ConsentRequestException(500, null));
        sut.Api.StartResults.Enqueue(() => throw new PabloException(403, "Forbidden", RecordingConsent.ConsentNeededErrorCode));
        sut.Api.Checks.Enqueue(() => throw new ConsentRequestException(500, null));

        await sut.Consent.RequestStartAsync("appt-1", null, null);

        Assert.Equal(ConsentPromptKind.AskOnRecording, sut.Consent.Prompt);
        Assert.Null(sut.Session.ErrorMessage);

        await sut.Consent.StartAndAskAsync();

        // The retention window is unknown, so no script rather than the wrong one.
        Assert.True(sut.Consent.IsAsking);
        Assert.Empty(sut.Consent.ScriptLines);
    }

    [Fact]
    public async Task A403Declined_TurnsIntoTheDeclinedPromptWithItsDate()
    {
        var sut = MakeSut();
        sut.Api.Checks.Enqueue(() => Check(RecordingConsent.ClearValue));
        sut.Api.StartResults.Enqueue(() => throw new PabloException(403, "Forbidden", RecordingConsent.DeclinedErrorCode,
            new Dictionary<string, string> { ["declined_on"] = "2026-09-01" }));

        await sut.Consent.RequestStartAsync("appt-1", "pat-9", AiConsentModality.InPerson);

        Assert.Equal(ConsentPromptKind.Declined, sut.Consent.Prompt);
        Assert.Equal(new RecordingConsent.Declined("2026-09-01"), sut.Consent.Consent);
        Assert.Null(sut.Session.ErrorMessage);
        Assert.Empty(sut.Recorder.Started);
    }

    [Fact]
    public async Task AnyOther403_IsTheSubscription()
    {
        var sut = MakeSut();
        sut.Api.Checks.Enqueue(() => Check(RecordingConsent.ClearValue, asks: false));
        sut.Api.StartResults.Enqueue(() => throw new PabloException(403, "Forbidden", "SUBSCRIPTION_REQUIRED"));

        await sut.Consent.RequestStartAsync("appt-1", "pat-9", AiConsentModality.InPerson);

        Assert.True(sut.Session.SubscriptionBlocked);
        Assert.Equal(ConsentPromptKind.None, sut.Consent.Prompt);
    }

    // --- the answer on the recording ---

    private async Task<Sut> AskingOnRecordingAsync()
    {
        var sut = MakeSut();
        sut.Api.Checks.Enqueue(() => Check(new RecordingConsent.AskOnRecording(AiConsentModality.Telehealth)));
        await sut.Consent.RequestStartAsync("appt-1", "pat-9", AiConsentModality.Telehealth);
        await sut.Consent.StartAndAskAsync();
        Assert.True(sut.Consent.IsAsking);
        return sut;
    }

    /// <summary>
    /// Two segments' worth of capture in the session directory, mapped and queued
    /// the way the app leaves a session it would otherwise upload.
    /// </summary>
    private string SeedRecordedSession(Sut sut, string sessionId)
    {
        var dir = Path.Join(_recordingsRoot, sessionId);
        Directory.CreateDirectory(dir);
        string Write(string name)
        {
            var path = Path.Join(dir, name);
            File.WriteAllBytes(path, new byte[512]);
            return path;
        }
        Write("seg1_mic.enc.pcm");
        Write("seg1_system.enc.pcm");
        var mixed = Write("seg2.enc.wav");
        var mic = Write("seg2_mic.enc.pcm");
        var system = Write("seg2_system.enc.pcm");

        _recordingStore.Save(sessionId, new LocalRecording(
            Id: Guid.NewGuid(), FilePath: mixed, Duration: 60, CreatedAt: DateTime.UtcNow,
            IsEncrypted: true, Checksum: "x", ChannelLayout: ChannelLayout.SeparatedStereo,
            MicPcmFilePath: mic, SystemPcmFilePath: system, IsUploaded: false));
        sut.Pending.Add(sessionId, mic, system, isEncrypted: true, sampleRate: 48000);
        return dir;
    }

    [Fact]
    public async Task ADeclineOnTheRecording_LeavesNoAudio_NoQueueEntry_AndTheSessionScheduled()
    {
        var sut = await AskingOnRecordingAsync();
        var dir = SeedRecordedSession(sut, SessionId);
        Assert.NotNull(sut.Pending.Get(SessionId));
        Assert.NotNull(_recordingStore.Get(SessionId));
        sut.Consent.Giver = AiConsentGiver.Guardian;
        sut.Consent.Location = "At home";

        await sut.Consent.AnswerAsync(AiConsentEntry.DeclinedDecision);

        Assert.False(Directory.Exists(dir));
        Assert.Null(sut.Pending.Get(SessionId));
        Assert.Null(_recordingStore.Get(SessionId));
        Assert.Null(sut.Recorder.ActiveSessionId);
        Assert.Equal(SessionStatus.Scheduled, sut.Api.Statuses[^1]);
        Assert.True(sut.Consent.RecordingDeleted);
        Assert.True(sut.Consent.IsAsking);
        Assert.Null(sut.Consent.SaveError);
        var (answer, patientId) = Assert.Single(sut.Api.Answers);
        Assert.Equal("pat-9", patientId);
        Assert.Equal(new AiConsentAnswer("declined", AiConsentModality.Telehealth, AiConsentGiver.Guardian, "At home"), answer);
    }

    [Fact]
    public async Task ADeclinedSession_UploadsNothing()
    {
        var sut = await AskingOnRecordingAsync();
        SeedRecordedSession(sut, SessionId);

        await sut.Consent.AnswerAsync(AiConsentEntry.DeclinedDecision);

        // Neither the queue drains nor an end-of-session upload sends it.
        await sut.Transcription.ForceRetryPendingUploadsAsync();
        await sut.Transcription.ResumePendingUploadsAsync();
        _recordingStore.Save(SessionId, new LocalRecording(
            Id: Guid.NewGuid(), FilePath: "x.wav", Duration: 1, CreatedAt: DateTime.UtcNow,
            IsEncrypted: false, Checksum: "x", ChannelLayout: ChannelLayout.SeparatedStereo,
            MicPcmFilePath: "x_mic.pcm", SystemPcmFilePath: null, IsUploaded: false));
        await sut.Transcription.UploadAudioAsync(SessionId);
        Assert.Equal(0, sut.Api.UploadCount);
        Assert.Null(sut.Pending.Get(SessionId));
    }

    [Fact]
    public async Task TheAudioIsDeletedEvenWhenSavingTheDeclineFails()
    {
        var sut = await AskingOnRecordingAsync();
        var dir = SeedRecordedSession(sut, SessionId);
        sut.Api.FailRecord = true;

        await sut.Consent.AnswerAsync(AiConsentEntry.DeclinedDecision);

        Assert.False(Directory.Exists(dir));
        Assert.Null(sut.Pending.Get(SessionId));
        Assert.True(sut.Consent.RecordingDeleted);
        Assert.Equal(RecordingConsentCopy.SaveFailed, sut.Consent.SaveError);

        // Trying the save again does not stop or delete anything twice.
        sut.Api.FailRecord = false;
        var patches = sut.Api.Statuses.Count;
        await sut.Consent.AnswerAsync(AiConsentEntry.DeclinedDecision);
        Assert.Null(sut.Consent.SaveError);
        Assert.Equal(patches, sut.Api.Statuses.Count);
        Assert.Single(sut.Api.Answers);
    }

    [Fact]
    public async Task AnAgreement_SavesAndClosesThePanel_AndRecordingCarriesOn()
    {
        var sut = await AskingOnRecordingAsync();
        var dir = SeedRecordedSession(sut, SessionId);

        await sut.Consent.AnswerAsync(AiConsentEntry.ConsentedDecision);

        Assert.False(sut.Consent.IsAsking);
        Assert.Equal(SessionId, sut.Recorder.ActiveSessionId);
        Assert.True(Directory.Exists(dir));
        Assert.NotNull(sut.Pending.Get(SessionId));
        Assert.Equal("consented", Assert.Single(sut.Api.Answers).Answer.Decision);
    }

    [Fact]
    public async Task ADeclineAfterTheRecordingEnded_DeletesNothing_ButStillSavesTheAnswer()
    {
        var sut = await AskingOnRecordingAsync();
        var dir = SeedRecordedSession(sut, SessionId);
        await sut.Recorder.StopAsync();

        await sut.Consent.AnswerAsync(AiConsentEntry.DeclinedDecision);

        Assert.True(Directory.Exists(dir));
        Assert.False(sut.Consent.RecordingDeleted);
        Assert.Single(sut.Api.Answers);
    }

    // --- RecordingCleaner.DiscardDeclined ---

    [Fact]
    public void Discarding_LeavesOtherSessionsAlone()
    {
        var sut = MakeSut();
        var declinedDir = SeedRecordedSession(sut, "session-D");
        var otherDir = SeedRecordedSession(sut, "session-other");

        var gone = new RecordingCleaner(_recordingsRoot).DiscardDeclined("session-D", _recordingStore, sut.Pending);

        Assert.True(gone);
        Assert.False(Directory.Exists(declinedDir));
        Assert.True(Directory.Exists(otherDir));
        Assert.NotNull(sut.Pending.Get("session-other"));
        Assert.NotNull(_recordingStore.Get("session-other"));
        Assert.Null(_recordingStore.Get("session-D"));
    }

    // --- stubs ---

    private sealed class StubCredentialManager : CredentialManager
    {
        private static readonly byte[] FixedKey = NewKey();
        private static byte[] NewKey() { var k = new byte[32]; RandomNumberGenerator.Fill(k); return k; }
        public override byte[]? GetOrCreateUserEncryptionKey() => FixedKey;
    }

    /// <summary>Capture that starts and stops on command, with no microphone.</summary>
    private sealed class FakeRecorder : ISessionRecorder
    {
        public string? ActiveSessionId { get; private set; }
        public List<string> Started { get; } = [];

        /// <summary>Capture fails to start, as with no key or a refused microphone.</summary>
        public bool FailStart { get; set; }

        public Task<bool> StartForSessionAsync(string sessionId)
        {
            Started.Add(sessionId);
            if (FailStart) return Task.FromResult(false);
            ActiveSessionId = sessionId;
            return Task.FromResult(true);
        }

        public Task StopAsync()
        {
            ActiveSessionId = null;
            return Task.CompletedTask;
        }
    }

    private sealed class ConsentStubApi(CredentialManager credentials) : APIClient(credentials)
    {
        public Queue<Func<RecordingConsentCheck>> Checks { get; } = new();
        public List<AiConsentModality?> CheckModalities { get; } = [];
        public Queue<Func<Session>> StartResults { get; } = new();
        public List<(string AppointmentId, bool Asking)> Starts { get; } = [];
        public List<SessionStatus> Statuses { get; } = [];
        public List<(AiConsentAnswer Answer, string PatientId)> Answers { get; } = [];
        public bool FailRecord { get; set; }
        public int UploadCount { get; private set; }

        public TaskCompletionSource? HoldCheck { get; set; }

        public override async Task<RecordingConsentCheck> CheckRecordingConsentAsync(
            string appointmentId, string? patientId, AiConsentModality? modality)
        {
            CheckModalities.Add(modality);
            if (HoldCheck is { } hold) await hold.Task;
            Assert.True(Checks.Count > 0, "unexpected consent check");
            return Checks.Dequeue()();
        }

        public override Task RecordConsentAsync(AiConsentAnswer answer, string patientId)
        {
            if (FailRecord) throw new ConsentRequestException(500, null);
            Answers.Add((answer, patientId));
            return Task.CompletedTask;
        }

        public override Task<Session> StartSessionFromAppointmentAsync(
            string appointmentId, bool askingConsentOnRecording = false)
        {
            Starts.Add((appointmentId, askingConsentOnRecording));
            return Task.FromResult(StartResults.Count > 0
                ? StartResults.Dequeue()()
                : MakeSession(SessionId, SessionStatus.Scheduled));
        }

        public override Task<Session> UpdateSessionStatusAsync(string sessionId, SessionStatus status)
        {
            Statuses.Add(status);
            return Task.FromResult(MakeSession(sessionId, status));
        }

        public override Task<AudioUploadResponse> UploadAudioWithSelfHealAsync(
            string sessionId, string therapistAudioPath, string? clientAudioPath = null,
            Func<byte[], byte[]>? decryptChunk = null, int sampleRate = AudioUploadClient.DefaultSampleRate)
        {
            UploadCount++;
            return Task.FromResult(new AudioUploadResponse(
                Id: sessionId, Status: "recording_complete", Queue: "transcribe", Message: "ok"));
        }

        public override Task<bool> VerifySessionAliveAsync() => Task.FromResult(true);

        public override Task<Session> FetchSessionAsync(string sessionId)
            => Task.FromResult(MakeSession(sessionId, SessionStatus.Transcribing));

        public override Task<Session[]> FetchTodaySessionsAsync(string timezone)
            => Task.FromResult(Array.Empty<Session>());

        public override Task<Appointment[]> FetchTodayAppointmentsAsync()
            => Task.FromResult(Array.Empty<Appointment>());

        private static Session MakeSession(string id, SessionStatus status) => new(
            Id: id, PatientId: null, Patient: null, Status: status,
            ScheduledAt: null, StartedAt: null, EndedAt: null,
            DurationMinutes: null, VideoLink: null, VideoPlatform: null,
            SessionType: null, Source: null, Notes: null,
            CreatedAt: null, UpdatedAt: null);
    }
}
