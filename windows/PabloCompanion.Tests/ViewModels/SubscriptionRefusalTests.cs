using PabloCompanion.Core;
using PabloCompanion.Helpers;
using PabloCompanion.Models;
using PabloCompanion.Services;
using PabloCompanion.Tests.Helpers;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Tests.ViewModels;

/// <summary>
/// A Start Session the server refuses on the subscription (403) says
/// "Subscribe to start sessions." and refreshes the subscription banner, so the
/// clinician sees the lapsed state and its Manage subscription button without
/// restarting the app.
/// </summary>
[Collection("SessionRecordingStore")]
public sealed class SubscriptionRefusalTests : IDisposable
{
    private readonly string _pendingPath = Path.Join(
        Path.GetTempPath(), $"pending-{Guid.NewGuid():N}.enc.json");
    private readonly string _recordingsRoot = Path.Join(
        Path.GetTempPath(), $"recordings-{Guid.NewGuid():N}");
    private readonly KeyCredentialManager _credentials = new(null);
    private readonly SessionRecordingStore _recordingStore = new();

    public SubscriptionRefusalTests()
    {
        Directory.CreateDirectory(_recordingsRoot);
    }

    [Fact]
    public async Task StartRefusedOnSubscription_SaysSubscribeAndRefreshesTheBanner()
    {
        var api = new StubApiClient(_credentials);
        var sessionVm = MakeSessionVm(api);
        var subscriptionVm = new SubscriptionViewModel(api);
        subscriptionVm.WatchForSubscriptionRefusals(sessionVm);
        Assert.Equal("hidden", subscriptionVm.BannerKind);

        var outcome = await sessionVm.StartAppointmentSessionAsync("appointment-1");

        Assert.Equal(AppointmentStartKind.Failed, outcome.Kind);
        Assert.Equal("Subscribe to start sessions.", sessionVm.StartErrorMessage);
        Assert.Equal(1, api.StatusFetchCount);
        Assert.Equal("trial_expired", subscriptionVm.BannerKind);
        // Reset so the next refusal fires the refresh again.
        Assert.False(sessionVm.SubscriptionBlocked);
    }

    [Fact]
    public async Task EachRefusal_RefreshesAgain()
    {
        var api = new StubApiClient(_credentials);
        var sessionVm = MakeSessionVm(api);
        var subscriptionVm = new SubscriptionViewModel(api);
        subscriptionVm.WatchForSubscriptionRefusals(sessionVm);

        await sessionVm.StartAppointmentSessionAsync("appointment-1");
        await sessionVm.StartAppointmentSessionAsync("appointment-1");

        Assert.Equal(2, api.StatusFetchCount);
    }

    private SessionViewModel MakeSessionVm(StubApiClient api)
    {
        var transcriptionVm = new TranscriptionViewModel(
            _recordingStore, new PendingTranscriptionStore(_credentials, _pendingPath), api,
            _credentials, new RecordingCleaner(_recordingsRoot));
        var recordingVm = new RecordingViewModel(new RecordingService(_credentials), _recordingStore);
        return new SessionViewModel(api, new VideoLaunchService(), recordingVm, transcriptionVm);
    }

    public void Dispose()
    {
        _recordingStore.Clear();
        try { if (File.Exists(_pendingPath)) File.Delete(_pendingPath); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        try { if (Directory.Exists(_recordingsRoot)) Directory.Delete(_recordingsRoot, recursive: true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private sealed class StubApiClient(CredentialManager credentials) : APIClient(credentials)
    {
        public int StatusFetchCount { get; private set; }

        public override Task<bool> VerifySessionAliveAsync() => Task.FromResult(true);

        public override Task<Appointment[]> FetchTodayAppointmentsAsync()
            => Task.FromResult(Array.Empty<Appointment>());

        public override Task<Session[]> FetchTodaySessionsAsync(string timezone)
            => Task.FromResult(Array.Empty<Session>());

        public override Task<Session> StartSessionFromAppointmentAsync(
            string appointmentId, bool askingConsentOnRecording = false)
            => throw new PabloException(403, "Subscription required", errorCode: "SUBSCRIPTION_REQUIRED");

        public override Task<SubscriptionInfo> FetchSubscriptionStatusAsync()
        {
            StatusFetchCount++;
            return Task.FromResult(new SubscriptionInfo(
                Status: "trial_expired", Plan: "solo",
                TrialSessionsUsed: null, TrialSessionsLimit: null, TrialDaysLimit: null,
                TrialStart: null, GraceExtensionAvailable: false, GraceExtensionExpiresAt: null));
        }
    }
}
