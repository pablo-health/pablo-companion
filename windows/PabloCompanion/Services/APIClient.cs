using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using PabloCompanion.Models;

namespace PabloCompanion.Services;

/// <summary>
/// Native HttpClient-based API client for the Pablo backend.
/// Mirrors APIClient.swift on macOS.
/// </summary>
public sealed class APIClient
{
    private static readonly HttpClient Http = new();

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
    };

    private const string ClientVersion = "1.0.0";
    private const string MinServerVersion = "1.0.0";
    private const string ClientPlatform = "windows";
    private const string ClientTypeHeader = "pablo-companion-windows/1.0";

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

    // ── Private helpers ─────────────────────────────────────────────────────

    private HttpRequestMessage CreateRequest(HttpMethod method, string path, bool authenticated = true)
    {
        var request = new HttpRequestMessage(method, $"{BaseUrl}{path}");
        request.Headers.Add("X-Client-Type", ClientTypeHeader);
        request.Headers.Add("X-Client-Version", ClientVersion);
        request.Headers.Add("X-Client-Platform", ClientPlatform);

        if (authenticated)
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", GetToken());
        }

        return request;
    }

    private async Task<T> SendAsync<T>(HttpRequestMessage request)
    {
        var response = await Http.SendAsync(request);

        if (!response.IsSuccessStatusCode)
        {
            await HandleErrorResponse(response);
        }

        var body = await response.Content.ReadAsStringAsync();
        return JsonSerializer.Deserialize<T>(body, JsonOptions)
            ?? throw new InvalidOperationException($"Failed to deserialize response as {typeof(T).Name}");
    }

    private static async Task HandleErrorResponse(HttpResponseMessage response)
    {
        var statusCode = (ushort)response.StatusCode;
        var body = await response.Content.ReadAsStringAsync();

        throw statusCode switch
        {
            401 => new PabloApiException(statusCode, "Unauthenticated"),
            403 => new PabloApiException(statusCode, "Forbidden"),
            404 => new PabloApiException(statusCode, string.IsNullOrWhiteSpace(body) ? "Not found" : body),
            409 => new PabloApiException(statusCode, string.IsNullOrWhiteSpace(body) ? "Conflict" : body),
            426 => new PabloApiException(statusCode, "Update required"),
            _ => new PabloApiException(statusCode, $"HTTP {statusCode}: {body}"),
        };
    }

    /// <summary>
    /// Parse a semver string (e.g. "1.2.3") into a comparable tuple.
    /// Missing parts default to 0: "1.2" -> (1, 2, 0), "1" -> (1, 0, 0).
    /// </summary>
    private static (int Major, int Minor, int Patch) ParseSemver(string version)
    {
        var parts = version.Trim().Split('.');
        int Part(int index) => parts.Length > index && int.TryParse(parts[index], out var v) ? v : 0;
        return (Part(0), Part(1), Part(2));
    }

    // ── Health ──────────────────────────────────────────────────────────────

    public async Task<HealthStatus> HealthCheckAsync()
    {
        using var request = CreateRequest(HttpMethod.Get, "/api/health", authenticated: false);
        var response = await Http.SendAsync(request);

        if (!response.IsSuccessStatusCode)
        {
            await HandleErrorResponse(response);
        }

        var body = await response.Content.ReadAsStringAsync();

        // Parse as raw JSON to extract nested min_client_versions.windows.
        using var doc = JsonDocument.Parse(body);
        var root = doc.RootElement;

        var serverVersion = root.TryGetProperty("server_version", out var sv) ? sv.GetString() ?? "" : "";

        var minClientVersion = "0.0.0";
        if (root.TryGetProperty("min_client_versions", out var mcv)
            && mcv.TryGetProperty("windows", out var winVersion))
        {
            minClientVersion = winVersion.GetString() ?? "0.0.0";
        }

        // Compare versions.
        var clientUpdateRequired = ParseSemver(ClientVersion).CompareTo(ParseSemver(minClientVersion)) < 0;

        var serverUpdateRequired = string.IsNullOrEmpty(serverVersion)
            ? false
            : ParseSemver(serverVersion).CompareTo(ParseSemver(MinServerVersion)) < 0;

        return new HealthStatus(
            ServerVersion: serverVersion,
            ClientUpdateRequired: clientUpdateRequired,
            ServerUpdateRequired: serverUpdateRequired,
            MinClientVersion: minClientVersion,
            MinServerVersion: MinServerVersion
        );
    }

    // ── Sessions ────────────────────────────────────────────────────────────

    public async Task<Session[]> FetchTodaySessionsAsync(string timezone)
    {
        using var request = CreateRequest(HttpMethod.Get,
            $"/api/sessions/today?timezone={Uri.EscapeDataString(timezone)}");
        var result = await SendAsync<SessionListResponse>(request);
        return result.Data;
    }

    public async Task<Session> CreateSessionAsync(CreateSessionRequest sessionRequest)
    {
        using var request = CreateRequest(HttpMethod.Post, "/api/sessions/schedule");
        request.Content = new StringContent(
            JsonSerializer.Serialize(sessionRequest, JsonOptions),
            Encoding.UTF8,
            "application/json");
        return await SendAsync<Session>(request);
    }

    public async Task<Session> FetchSessionAsync(string sessionId)
    {
        using var request = CreateRequest(HttpMethod.Get, $"/api/sessions/{Uri.EscapeDataString(sessionId)}");
        return await SendAsync<Session>(request);
    }

    public async Task<SessionListResponse> FetchSessionsAsync(uint page, uint pageSize, string? status = null)
    {
        var path = $"/api/sessions?page={page}&page_size={pageSize}";
        if (!string.IsNullOrEmpty(status))
        {
            path += $"&status={Uri.EscapeDataString(status)}";
        }
        using var request = CreateRequest(HttpMethod.Get, path);
        return await SendAsync<SessionListResponse>(request);
    }

    public async Task<Session> UpdateSessionStatusAsync(string sessionId, SessionStatus status)
    {
        using var request = CreateRequest(HttpMethod.Patch,
            $"/api/sessions/{Uri.EscapeDataString(sessionId)}/status");
        var statusJson = JsonSerializer.Serialize(new { status }, JsonOptions);
        request.Content = new StringContent(statusJson, Encoding.UTF8, "application/json");
        return await SendAsync<Session>(request);
    }

    public async Task<Session> UpdateSessionAsync(string sessionId, UpdateSessionRequest sessionRequest)
    {
        using var request = CreateRequest(HttpMethod.Patch,
            $"/api/sessions/{Uri.EscapeDataString(sessionId)}");
        request.Content = new StringContent(
            JsonSerializer.Serialize(sessionRequest, JsonOptions),
            Encoding.UTF8,
            "application/json");
        return await SendAsync<Session>(request);
    }

    public async Task<Session> FinalizeSessionAsync(string sessionId, byte qualityRating)
    {
        using var request = CreateRequest(HttpMethod.Patch,
            $"/api/sessions/{Uri.EscapeDataString(sessionId)}/finalize");
        var body = JsonSerializer.Serialize(new { quality_rating = qualityRating });
        request.Content = new StringContent(body, Encoding.UTF8, "application/json");
        return await SendAsync<Session>(request);
    }

    // ── Patients ────────────────────────────────────────────────────────────

    public async Task<PatientListResponse> FetchPatientsAsync(string? search = null, uint page = 1, uint pageSize = 50)
    {
        var path = $"/api/patients?page={page}&page_size={pageSize}";
        if (!string.IsNullOrEmpty(search))
        {
            path += $"&search={Uri.EscapeDataString(search)}";
        }
        using var request = CreateRequest(HttpMethod.Get, path);
        return await SendAsync<PatientListResponse>(request);
    }

    public async Task<Patient> CreatePatientAsync(CreatePatientRequest patientRequest)
    {
        using var request = CreateRequest(HttpMethod.Post, "/api/patients");
        request.Content = new StringContent(
            JsonSerializer.Serialize(patientRequest, JsonOptions),
            Encoding.UTF8,
            "application/json");
        return await SendAsync<Patient>(request);
    }

    // ── User ────────────────────────────────────────────────────────────────

    public async Task<UserProfile> FetchUserProfileAsync()
    {
        using var request = CreateRequest(HttpMethod.Get, "/api/users/me");
        return await SendAsync<UserProfile>(request);
    }

    // ── BAA ─────────────────────────────────────────────────────────────────

    public async Task<BaaStatus> FetchBaaStatusAsync()
    {
        using var request = CreateRequest(HttpMethod.Get, "/api/users/me/baa-status");
        return await SendAsync<BaaStatus>(request);
    }

    public async Task<BaaStatus> AcceptBaaAsync()
    {
        using var request = CreateRequest(HttpMethod.Post, "/api/users/me/accept-baa");
        return await SendAsync<BaaStatus>(request);
    }

    // ── Preferences ─────────────────────────────────────────────────────────

    public async Task<UserPreferences> FetchPreferencesAsync()
    {
        using var request = CreateRequest(HttpMethod.Get, "/api/users/me/preferences");
        return await SendAsync<UserPreferences>(request);
    }

    public async Task<UserPreferences> SavePreferencesAsync(UserPreferences preferences)
    {
        using var request = CreateRequest(HttpMethod.Put, "/api/users/me/preferences");
        request.Content = new StringContent(
            JsonSerializer.Serialize(preferences, JsonOptions),
            Encoding.UTF8,
            "application/json");
        return await SendAsync<UserPreferences>(request);
    }

    // ── Transcripts ─────────────────────────────────────────────────────────

    public async Task<TranscriptUploadResponse> UploadTranscriptAsync(string sessionId, string format, string content)
    {
        using var request = CreateRequest(HttpMethod.Post,
            $"/api/sessions/{Uri.EscapeDataString(sessionId)}/transcript");
        var body = JsonSerializer.Serialize(new { format, content }, JsonOptions);
        request.Content = new StringContent(body, Encoding.UTF8, "application/json");
        return await SendAsync<TranscriptUploadResponse>(request);
    }

    // ── Recordings ──────────────────────────────────────────────────────────

    public async Task<UploadResponse> UploadRecordingAsync(string filePath)
    {
        using var request = CreateRequest(HttpMethod.Post, "/api/recordings/upload");
        using var formContent = new MultipartFormDataContent();
        var fileStream = new StreamContent(File.OpenRead(filePath));
        fileStream.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        formContent.Add(fileStream, "file", Path.GetFileName(filePath));
        request.Content = formContent;
        return await SendAsync<UploadResponse>(request);
    }

    // ── Audio Upload (native HttpClient) ────────────────────────────────────

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
        request.Headers.Add("X-Client-Type", ClientTypeHeader);
        request.Headers.Add("X-Client-Version", ClientVersion);
        request.Headers.Add("X-Client-Platform", ClientPlatform);

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
