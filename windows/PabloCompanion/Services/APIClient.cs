using uniffi.pablo_core;

namespace PabloCompanion.Services;

/// <summary>
/// Thin wrapper over UniFFI-generated Rust bindings.
/// Mirrors APIClient.swift on macOS.
/// </summary>
public sealed class APIClient
{
    private readonly CredentialManager _credentials;

    public string BaseUrl { get; set; } = "https://api.pablo.health";

    public APIClient(CredentialManager credentials)
    {
        _credentials = credentials;
    }

    private string GetToken()
    {
        return _credentials.IdToken
            ?? throw new InvalidOperationException("Not authenticated");
    }

    // Health

    public async Task HealthCheckAsync()
    {
        await PabloCoreMethods.HealthCheck(BaseUrl);
    }

    // Sessions

    public async Task<Session[]> FetchTodaySessionsAsync(string timezone)
    {
        return await PabloCoreMethods.FetchTodaySessions(BaseUrl, GetToken(), timezone);
    }

    public async Task<Session> CreateSessionAsync(CreateSessionRequest request)
    {
        return await PabloCoreMethods.CreateSession(BaseUrl, GetToken(), request);
    }

    public async Task<Session> FetchSessionAsync(string sessionId)
    {
        return await PabloCoreMethods.FetchSession(BaseUrl, GetToken(), sessionId);
    }

    public async Task<SessionListResponse> FetchSessionsAsync(uint page, uint pageSize, string? status = null)
    {
        return await PabloCoreMethods.FetchSessions(BaseUrl, GetToken(), page, pageSize, status);
    }

    public async Task<Session> UpdateSessionStatusAsync(string sessionId, SessionStatus status)
    {
        return await PabloCoreMethods.UpdateSessionStatus(BaseUrl, GetToken(), sessionId, status);
    }

    public async Task<Session> UpdateSessionAsync(string sessionId, UpdateSessionRequest request)
    {
        return await PabloCoreMethods.UpdateSession(BaseUrl, GetToken(), sessionId, request);
    }

    public async Task<Session> FinalizeSessionAsync(string sessionId, byte qualityRating)
    {
        return await PabloCoreMethods.FinalizeSession(BaseUrl, GetToken(), sessionId, qualityRating);
    }

    // Patients

    public async Task<PatientListResponse> FetchPatientsAsync(string? search = null, uint page = 1, uint pageSize = 50)
    {
        return await PabloCoreMethods.FetchPatients(BaseUrl, GetToken(), search, page, pageSize);
    }

    public async Task<Patient> CreatePatientAsync(CreatePatientRequest request)
    {
        return await PabloCoreMethods.CreatePatient(BaseUrl, GetToken(), request);
    }

    // User

    public async Task<UserProfile> FetchUserProfileAsync()
    {
        return await PabloCoreMethods.FetchUserProfile(BaseUrl, GetToken());
    }

    // Transcripts

    public async Task<TranscriptUploadResponse> UploadTranscriptAsync(string sessionId, string format, string content)
    {
        return await PabloCoreMethods.UploadTranscript(BaseUrl, GetToken(), sessionId, format, content);
    }

    // Recordings

    public async Task<UploadResponse> UploadRecordingAsync(string filePath)
    {
        return await PabloCoreMethods.UploadRecording(BaseUrl, GetToken(), filePath);
    }

    // BAA

    public async Task<BaaStatus> FetchBaaStatusAsync()
    {
        return await PabloCoreMethods.FetchBaaStatus(BaseUrl, GetToken());
    }

    public async Task<BaaStatus> AcceptBaaAsync()
    {
        return await PabloCoreMethods.AcceptBaa(BaseUrl, GetToken());
    }

    // Preferences

    public async Task<UserPreferences> FetchPreferencesAsync()
    {
        return await PabloCoreMethods.FetchPreferences(BaseUrl, GetToken());
    }

    public async Task<UserPreferences> SavePreferencesAsync(UserPreferences preferences)
    {
        return await PabloCoreMethods.SavePreferences(BaseUrl, GetToken(), preferences);
    }
}
