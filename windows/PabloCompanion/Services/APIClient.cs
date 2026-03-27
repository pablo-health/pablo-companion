using System.Net.Http.Headers;
using System.Text.Json;
using uniffi.pablo_core;

namespace PabloCompanion.Services;

/// <summary>
/// Thin wrapper over UniFFI-generated Rust bindings.
/// Mirrors APIClient.swift on macOS.
/// </summary>
public sealed class APIClient
{
    private static readonly HttpClient Http = new();

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
    };

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

    // Audio Upload (native HttpClient — not via Rust core)

    /// <summary>
    /// Uploads therapist and client audio files to the backend for server-side transcription.
    /// Uses native HttpClient multipart/form-data since this endpoint is not in pablo-core.
    /// </summary>
    /// <param name="sessionId">Backend session UUID (must be in recording_complete status).</param>
    /// <param name="therapistAudioPath">Path to the mic PCM/WAV file.</param>
    /// <param name="clientAudioPath">Path to the system audio PCM/WAV file (optional).</param>
    public async Task<AudioUploadResponse> UploadAudioAsync(
        string sessionId,
        string therapistAudioPath,
        string? clientAudioPath = null)
    {
        var token = GetToken();
        var url = $"{BaseUrl}/api/sessions/{sessionId}/upload-audio";

        using var content = new MultipartFormDataContent();

        var therapistStream = new StreamContent(File.OpenRead(therapistAudioPath));
        therapistStream.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
        content.Add(therapistStream, "therapist_audio", Path.GetFileName(therapistAudioPath));

        if (clientAudioPath != null && File.Exists(clientAudioPath))
        {
            var clientStream = new StreamContent(File.OpenRead(clientAudioPath));
            clientStream.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
            content.Add(clientStream, "client_audio", Path.GetFileName(clientAudioPath));
        }

        using var request = new HttpRequestMessage(HttpMethod.Post, url) { Content = content };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Headers.Add("X-Client-Type", "pablo-companion-windows/1.0");

        var response = await Http.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();

        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"Audio upload failed ({(int)response.StatusCode}): {body}");

        return JsonSerializer.Deserialize<AudioUploadResponse>(body, JsonOptions)
            ?? throw new InvalidOperationException("Failed to parse audio upload response");
    }
}

/// <summary>
/// Response from POST /api/sessions/{session_id}/upload-audio.
/// </summary>
public sealed record AudioUploadResponse(
    string Id,
    string Status,
    string Queue,
    string Message);
