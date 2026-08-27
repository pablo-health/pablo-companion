using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using PabloCompanion.Core;
using PabloCompanion.Models;

namespace PabloCompanion.Services;

/// <summary>
/// Native HttpClient-based API client for the Pablo backend.
/// Mirrors APIClient.swift on macOS.
/// </summary>
public class APIClient
{
    private static readonly HttpClient Http = new();

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
    };

    private const string ClientVersion = "1.0.0";
    private const string MinServerVersion = "0.9.0";
    private const string ClientPlatform = "windows";
    private const string ClientTypeHeader = "pablo-companion-windows/1.0";

    private const string DefaultBaseUrl = "https://api.pablo.health";

    private readonly CredentialManager _credentials;
    private readonly DeviceKeyService _deviceKey;

    /// <summary>
    /// The session audio-upload wire path, shared with the headless end-to-end
    /// runner via <c>PabloCompanion.Core</c> so the two cannot drift. Its base URL
    /// and device binding are read through delegates, so a backend rediscovery or a
    /// fresh enrollment is picked up on the next request.
    /// </summary>
    private readonly AudioUploadClient _uploadClient;

    public string BaseUrl { get; set; }

    /// <summary>
    /// Structured error code the backend attaches to idle-timeout 401s. The
    /// server-side idle session cannot be revived by a token refresh (the
    /// tombstone is keyed on <c>auth_time</c>, which a refresh preserves) —
    /// only a fresh interactive sign-in recovers.
    /// </summary>
    public const string IdleTimeoutCode = "IDLE_TIMEOUT";

    /// <summary>
    /// Raised when an authenticated request comes back 401. AuthViewModel listens
    /// and signs the user out so the UI returns to the login screen instead of
    /// leaving the user stuck on a page that can't load data. The argument is the
    /// structured <c>error.code</c> from the response body (null when absent);
    /// <see cref="IdleTimeoutCode"/> means the server-side idle session expired,
    /// which gets a distinct user-facing message.
    /// Not raised for HealthCheck (unauthenticated endpoint).
    /// </summary>
    public event Action<string?>? UnauthenticatedDetected;

    public APIClient(CredentialManager credentials, DeviceKeyService? deviceKey = null)
    {
        _credentials = credentials;
        // Default-construct from the same credential vault when DI doesn't supply one
        // (keeps the single-arg signature the tests use working). The device key only
        // signs DPoP proofs; it touches the vault lazily, so this is cheap.
        _deviceKey = deviceKey ?? new DeviceKeyService(credentials);
        // Seed from the previously discovered backend URL so a restored session
        // starts on the correct env before AuthViewModel.DiscoverServerConfigAsync runs.
        BaseUrl = credentials.BackendApiUrl ?? DefaultBaseUrl;

        _uploadClient = new AudioUploadClient(
            baseUrl: () => BaseUrl,
            token: () => Task.FromResult(GetToken()),
            attachBinding: AttachDeviceBinding,
            clientHeaders: new Dictionary<string, string>
            {
                ["X-Client-Type"] = ClientTypeHeader,
                ["X-Client-Version"] = ClientVersion,
                ["X-Client-Platform"] = ClientPlatform,
            },
            http: Http,
            log: App.Log);
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
            AttachDeviceBinding(request);
        }

        return request;
    }

    /// <summary>
    /// Attaches the device-binding headers (<c>DPoP</c> proof + <c>X-Install-ID</c>) to
    /// an authenticated request when, and only when, this install is enrolled — i.e. an
    /// install id is persisted AND a device key exists to sign a fresh proof for this
    /// exact method + URL.
    ///
    /// The two headers are coupled by design. The server's DPoP middleware treats an
    /// <c>X-Install-ID</c> with no valid proof as a hard 401, so we never send the id
    /// without a proof — not when unenrolled, and not when signing throws. Either both
    /// headers go on the request, or neither does and it falls through as a legacy
    /// Firebase-bearer request (which the middleware passes). See
    /// <c>docs/design/companion-dpop-binding.md</c>.
    /// </summary>
    private void AttachDeviceBinding(HttpRequestMessage request)
    {
        if (request.RequestUri is null) return;

        var (proof, installId) = BuildDeviceBinding(
            request.Method.Method, request.RequestUri.ToString());
        if (proof is null || installId is null) return;

        request.Headers.Add("DPoP", proof);
        request.Headers.Add("X-Install-ID", installId);
    }

    /// <summary>
    /// Computes the device-binding header pair for a request, or <c>(null, null)</c>
    /// when this install isn't enrolled (no install id, no key) or signing fails. The
    /// pair is all-or-nothing on purpose: returning a non-null install id with a null
    /// proof would let a caller attach the id alone, which the server's DPoP middleware
    /// rejects with a 401. Internal so the enrollment-state matrix is unit-testable
    /// without a live <see cref="HttpClient"/>.
    /// </summary>
    internal (string? Proof, string? InstallId) BuildDeviceBinding(string method, string url)
    {
        var installId = _credentials.InstallId;
        if (string.IsNullOrEmpty(installId)) return (null, null);

        try
        {
            var proof = _deviceKey.TryCreateProof(method, url);
            // No key yet (never enrolled) → neither header.
            return string.IsNullOrEmpty(proof) ? (null, null) : (proof, installId);
        }
        catch (Exception ex)
        {
            // A signing failure must not leave the id header on alone (guaranteed 401);
            // drop both and let the request go out as a legacy bearer request.
            App.LogException("APIClient.BuildDeviceBinding", ex);
            return (null, null);
        }
    }

    private async Task<T> SendAsync<T>(HttpRequestMessage request)
    {
        var response = await Http.SendAsync(request);

        if (!response.IsSuccessStatusCode)
        {
            await RaiseAndThrowErrorAsync(response);
        }

        var body = await response.Content.ReadAsStringAsync();
        return JsonSerializer.Deserialize<T>(body, JsonOptions)
            ?? throw new InvalidOperationException($"Failed to deserialize response as {typeof(T).Name}");
    }

    /// <summary>
    /// Raises <see cref="UnauthenticatedDetected"/> for a 401 — carrying the
    /// parsed <c>error.code</c> so listeners can distinguish an idle-timeout
    /// from a generic auth failure — then throws the mapped
    /// <see cref="PabloException"/>. Authenticated routes only; HealthCheck
    /// keeps using <see cref="HandleErrorResponse"/> so an unauthenticated
    /// endpoint can never trigger a sign-out.
    /// </summary>
    private async Task RaiseAndThrowErrorAsync(HttpResponseMessage response)
    {
        if (response.StatusCode == HttpStatusCode.Unauthorized)
        {
            var body = await response.Content.ReadAsStringAsync();
            var (_, errorCode) = TryParseErrorEnvelope(body);
            UnauthenticatedDetected?.Invoke(errorCode);
        }
        await HandleErrorResponse(response);
    }

    private static async Task HandleErrorResponse(HttpResponseMessage response)
    {
        var statusCode = (ushort)response.StatusCode;
        var body = await response.Content.ReadAsStringAsync();
        var (envelopeMessage, errorCode) = TryParseErrorEnvelope(body);

        throw statusCode switch
        {
            401 => new PabloException(statusCode, "Unauthenticated", errorCode),
            403 => new PabloException(statusCode, "Forbidden", errorCode),
            404 => new PabloException(statusCode, envelopeMessage ?? (string.IsNullOrWhiteSpace(body) ? "Not found" : body), errorCode),
            409 => new PabloException(statusCode, envelopeMessage ?? (string.IsNullOrWhiteSpace(body) ? "Conflict" : body), errorCode),
            426 => new PabloException(statusCode, "Update required", errorCode),
            _ => new PabloException(statusCode, envelopeMessage ?? $"HTTP {statusCode}: {body}", errorCode),
        };
    }

    /// <summary>
    /// Parses the standard backend error envelope (<c>{error: {code, message, details}}</c>)
    /// into <c>(message, code)</c>. Returns (null, null) for non-JSON or unrecognized bodies.
    /// Internal so the envelope shapes (including the idle-timeout code) are unit-testable.
    /// </summary>
    internal static (string? message, string? code) TryParseErrorEnvelope(string body)
    {
        if (string.IsNullOrWhiteSpace(body)) return (null, null);
        try
        {
            using var doc = JsonDocument.Parse(body);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return (null, null);
            if (!doc.RootElement.TryGetProperty("error", out var err) ||
                err.ValueKind != JsonValueKind.Object) return (null, null);

            var msg = err.TryGetProperty("message", out var m) && m.ValueKind == JsonValueKind.String
                ? m.GetString() : null;
            var code = err.TryGetProperty("code", out var c) && c.ValueKind == JsonValueKind.String
                ? c.GetString() : null;
            return (msg, code);
        }
        catch (JsonException) { return (null, null); }
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

        var serverUpdateRequired = !string.IsNullOrEmpty(serverVersion)
            && ParseSemver(serverVersion).CompareTo(ParseSemver(MinServerVersion)) < 0;

        return new HealthStatus(
            ServerVersion: serverVersion,
            ClientUpdateRequired: clientUpdateRequired,
            ServerUpdateRequired: serverUpdateRequired,
            MinClientVersion: minClientVersion,
            MinServerVersion: MinServerVersion
        );
    }

    // ── Appointments ───────────────────────────────────────────────────────

    public async Task<Appointment[]> FetchTodayAppointmentsAsync()
    {
        var start = DateTime.UtcNow.Date;
        var end = start.AddDays(1);
        var startStr = Uri.EscapeDataString(start.ToString("O"));
        var endStr = Uri.EscapeDataString(end.ToString("O"));
        using var request = CreateRequest(HttpMethod.Get,
            $"/api/appointments?start={startStr}&end={endStr}");
        var result = await SendAsync<AppointmentListResponse>(request);
        return result.Data;
    }

    public async Task<Session> StartSessionFromAppointmentAsync(string appointmentId)
    {
        using var request = CreateRequest(HttpMethod.Post,
            $"/api/appointments/{appointmentId}/start-session");
        return await SendAsync<Session>(request);
    }

    // ── Sessions ────────────────────────────────────────────────────────────

    public virtual async Task<Session[]> FetchTodaySessionsAsync(string timezone)
    {
        using var request = CreateRequest(HttpMethod.Get,
            $"/api/sessions/today?timezone={Uri.EscapeDataString(timezone)}");
        var result = await SendAsync<TodaySessionListResponse>(request);
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

    public virtual async Task<Session> FetchSessionAsync(string sessionId)
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

    public virtual async Task<Session> UpdateSessionStatusAsync(string sessionId, SessionStatus status)
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

    // ── Launch handoff ────────────────────────────────────────────────────────

    /// <summary>
    /// Redeems a single-use launch intent received via a verified deep link
    /// (or legacy-scheme fallback). On success the backend marks the intent
    /// consumed and returns the appointment + patient name to confirm.
    ///
    /// Throws <see cref="PabloException"/> with <c>StatusCode == 410</c> when the
    /// intent is no longer valid (already redeemed via the other path, expired,
    /// or unknown) — callers treat that as a benign "already handled / expired".
    /// Like every authenticated request, the device-binding headers (<c>DPoP</c> +
    /// <c>X-Install-ID</c>) are attached by <see cref="CreateRequest"/> when this
    /// install is enrolled, so the redeem path keeps working under server-side proof
    /// enforcement.
    /// </summary>
    public virtual async Task<RedeemLaunchIntentResponse> RedeemLaunchIntentAsync(string intentId)
    {
        using var request = CreateRequest(HttpMethod.Post, "/api/launch/redeem");
        var body = JsonSerializer.Serialize(new RedeemLaunchIntentRequest(intentId), JsonOptions);
        request.Content = new StringContent(body, Encoding.UTF8, "application/json");
        return await SendAsync<RedeemLaunchIntentResponse>(request);
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

    // ── Subscription ──────────────────────────────────────────────────────

    public async Task<SubscriptionInfo> FetchSubscriptionStatusAsync()
    {
        using var request = CreateRequest(HttpMethod.Get, "/api/users/me/status");
        var wrapper = await SendAsync<SubscriptionResponse>(request);
        return wrapper.Subscription
            ?? throw new InvalidOperationException("No subscription data in response");
    }

    public async Task<SubscriptionInfo> ExtendSubscriptionAsync()
    {
        using var request = CreateRequest(HttpMethod.Post, "/api/users/me/subscription/extend");
        return await SendAsync<SubscriptionInfo>(request);
    }

    // ── Session liveness ────────────────────────────────────────────────────

    /// <summary>
    /// Read-only peek at the server-side idle session. Does NOT extend the
    /// session — checking liveness must not keep it alive.
    /// </summary>
    public virtual async Task<SessionLiveness> FetchSessionStatusAsync()
    {
        using var request = CreateRequest(HttpMethod.Get, "/api/auth/session");
        return await SendAsync<SessionLiveness>(request);
    }

    /// <summary>
    /// Explicit keep-alive: refreshes the server-side idle heartbeat. Used
    /// while a recording is active, when the app makes no other backend calls
    /// and would otherwise idle out mid-session.
    /// </summary>
    public virtual async Task<SessionLiveness> TouchSessionAsync()
    {
        using var request = CreateRequest(HttpMethod.Post, "/api/auth/session/touch");
        return await SendAsync<SessionLiveness>(request);
    }

    /// <summary>
    /// Probes session liveness and reports whether it is safe to proceed with
    /// an authenticated call. Returns false only when the server positively
    /// says the session is dead (dead peek, or a 401 on the probe itself —
    /// <see cref="UnauthenticatedDetected"/> has already been raised in both
    /// cases). Network or parsing failures return true: the probe is advisory
    /// and must never block work that has its own retry path.
    /// </summary>
    public virtual async Task<bool> VerifySessionAliveAsync()
    {
        try
        {
            var status = await FetchSessionStatusAsync();
            if (status.Enforced && !status.Active)
            {
                UnauthenticatedDetected?.Invoke(IdleTimeoutCode);
                return false;
            }
            return true;
        }
        catch (PabloException ex) when (ex.StatusCode == 401)
        {
            return false;
        }
        catch (Exception)
        {
            return true;
        }
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

    // ── Audio Upload ────────────────────────────────────────────────────────

    /// <summary>
    /// Uploads therapist and client audio files to the backend for server-side
    /// transcription. The headerless PCM sidecars are given accurate WAV headers on
    /// the way out — see <see cref="WAVEncoder"/> for why that matters.
    /// </summary>
    /// <param name="sessionId">Backend session UUID (must be in recording_complete status).</param>
    /// <param name="therapistAudioPath">Path to the mic PCM/WAV file.</param>
    /// <param name="clientAudioPath">Path to the system audio PCM/WAV file (optional).</param>
    public virtual async Task<AudioUploadResponse> UploadAudioAsync(
        string sessionId,
        string therapistAudioPath,
        string? clientAudioPath = null)
    {
        try
        {
            return await _uploadClient.UploadAudioAsync(sessionId, therapistAudioPath, clientAudioPath);
        }
        catch (SessionUploadException ex)
        {
            throw TranslateUploadError(ex);
        }
    }

    /// <summary>
    /// Uploads audio, healing a <c>400 INVALID_STATUS</c> rejection once by PATCHing
    /// the session to <c>recording_complete</c> and retrying. Used by the pending-upload
    /// drain, where a session from a build that uploaded before its status PATCH landed
    /// would otherwise be stuck rejecting forever.
    /// </summary>
    public virtual async Task<AudioUploadResponse> UploadAudioWithSelfHealAsync(
        string sessionId,
        string therapistAudioPath,
        string? clientAudioPath = null)
    {
        try
        {
            return await _uploadClient.UploadWithSelfHealAsync(sessionId, therapistAudioPath, clientAudioPath);
        }
        catch (SessionUploadException ex)
        {
            throw TranslateUploadError(ex);
        }
    }

    /// <summary>
    /// Maps a core upload failure onto the app's <see cref="PabloException"/> so
    /// callers branch on one error type, and — as <see cref="RaiseAndThrowErrorAsync"/>
    /// does for every other authenticated route — raises
    /// <see cref="UnauthenticatedDetected"/> on a 401 so the UI returns to sign-in.
    /// </summary>
    private PabloException TranslateUploadError(SessionUploadException ex)
    {
        if (ex.StatusCode == 401)
            UnauthenticatedDetected?.Invoke(ex.ErrorCode);

        return new PabloException((ushort)ex.StatusCode, ex.Message, ex.ErrorCode);
    }
}
