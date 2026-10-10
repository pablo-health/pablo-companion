using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PabloCompanion.Core;

/// <summary>
/// Reads a client's answer about AI-assisted notes before a recording arms, and
/// records the client's answer.
///
/// Three existing endpoints, called with the clinician's own credentials:
/// <list type="bullet">
/// <item><c>GET /api/users/me/practice/ai-notes-consent</c>: whether the practice
/// asks, and its audio retention window (read aloud in the script).</item>
/// <item><c>GET /api/appointments/{id}</c>: the appointment's client, when the
/// caller only holds an appointment id (a web handoff carries no client id).</item>
/// <item><c>GET</c> / <c>POST /api/patients/{id}/ai-consent</c>: the client's answer.</item>
/// </list>
///
/// The setting is read first: with it off, the client is never looked up, so no
/// consent read is audited for a practice that does not ask.
///
/// Auth and device binding are injected, as for <see cref="AudioUploadClient"/>.
/// The C# mirror of macOS <c>CompanionSessionCore.RecordingConsentClient</c>.
/// </summary>
public sealed class RecordingConsentClient
{
    private readonly Func<string> _baseUrl;
    private readonly Func<Task<string>> _token;
    private readonly Action<HttpRequestMessage>? _attachBinding;
    private readonly IReadOnlyDictionary<string, string> _clientHeaders;
    private readonly HttpClient _http;

    /// <param name="baseUrl">Supplies the backend origin (no trailing slash).</param>
    /// <param name="token">Supplies a fresh Bearer token per request.</param>
    /// <param name="attachBinding">Stamps device-binding headers, or neither when unenrolled.</param>
    /// <param name="clientHeaders">Client identification headers (<c>X-Client-Type</c> etc.).</param>
    /// <param name="http">HttpClient for the backend calls. Defaults to a private instance.</param>
    public RecordingConsentClient(
        Func<string> baseUrl,
        Func<Task<string>> token,
        Action<HttpRequestMessage>? attachBinding = null,
        IReadOnlyDictionary<string, string>? clientHeaders = null,
        HttpClient? http = null)
    {
        ArgumentNullException.ThrowIfNull(baseUrl);
        ArgumentNullException.ThrowIfNull(token);

        _baseUrl = baseUrl;
        _token = token;
        _attachBinding = attachBinding;
        _clientHeaders = clientHeaders ?? new Dictionary<string, string>();
        _http = http ?? new HttpClient();
    }

    /// <summary>
    /// The consent picture for one appointment. Pass <paramref name="patientId"/>
    /// when it is already known (an appointment from today's list) to skip the
    /// appointment lookup.
    ///
    /// <paramref name="modality"/> is where the session is, when the caller knows.
    /// Null reads it from the appointment, which is looked up anyway when the
    /// client is not known; with the client known and null here, the session reads
    /// as in person.
    /// </summary>
    public async Task<RecordingConsentCheck> CheckAsync(
        string appointmentId,
        string? patientId = null,
        AiConsentModality? modality = null,
        CancellationToken cancellationToken = default)
    {
        var setting = await SendAsync<Setting>(HttpMethod.Get, "/api/users/me/practice/ai-notes-consent",
            null, cancellationToken);
        if (!setting.AskClientsAboutAiNotes)
            return new RecordingConsentCheck(RecordingConsent.ClearValue, false, setting.AudioRetentionDays, null);

        var clientId = patientId ?? "";
        var isTelehealth = modality == AiConsentModality.Telehealth;
        if (clientId.Length == 0)
        {
            var appointment = await SendAsync<AppointmentClient>(HttpMethod.Get,
                $"/api/appointments/{Uri.EscapeDataString(appointmentId)}", null, cancellationToken);
            clientId = appointment.PatientId ?? "";
            if (modality is null)
                isTelehealth = Telehealth.IsTelehealth(appointment.Provider, appointment.VideoLink, appointment.PlaceOfService);
        }
        if (clientId.Length == 0)
        {
            // No client matched to the appointment yet. The server refuses to
            // start such a session on its own; nothing to ask about here.
            return new RecordingConsentCheck(RecordingConsent.ClearValue, true, setting.AudioRetentionDays, null);
        }

        var record = await SendAsync<Record>(HttpMethod.Get,
            $"/api/patients/{Uri.EscapeDataString(clientId)}/ai-consent", null, cancellationToken);
        return new RecordingConsentCheck(
            RecordingConsent.Evaluate(asksClients: true, record.Current, telehealth: isTelehealth),
            true,
            setting.AudioRetentionDays,
            clientId);
    }

    /// <summary>Records the client's answer, with how it was given.</summary>
    public async Task RecordAsync(AiConsentAnswer answer, string patientId, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(answer);
        var body = JsonSerializer.Serialize(new SortedDictionary<string, string>(
            answer.Body.ToDictionary(kv => kv.Key, kv => kv.Value), StringComparer.Ordinal));
        _ = await SendAsync<Record>(HttpMethod.Post,
            $"/api/patients/{Uri.EscapeDataString(patientId)}/ai-consent", body, cancellationToken);
    }

    /// <summary>
    /// The body for <c>POST /api/appointments/{id}/start-session</c>. Null (no body,
    /// the server's defaults) unless the clinician is asking about AI-assisted notes
    /// once recording starts, which is what lets a telehealth session with no
    /// answer on file start at all.
    /// </summary>
    public static string? StartSessionBody(bool askingConsentOnRecording)
        => askingConsentOnRecording ? """{"asking_consent_on_recording":true}""" : null;

    // --- wire ---

    private sealed record Setting(
        [property: JsonPropertyName("ask_clients_about_ai_notes")] bool AskClientsAboutAiNotes,
        [property: JsonPropertyName("audio_retention_days")] int AudioRetentionDays);

    private sealed record AppointmentClient(
        [property: JsonPropertyName("patient_id")] string? PatientId = null,
        [property: JsonPropertyName("provider")] string? Provider = null,
        [property: JsonPropertyName("video_link")] string? VideoLink = null,
        [property: JsonPropertyName("place_of_service")] string? PlaceOfService = null);

    private sealed record Record(
        [property: JsonPropertyName("current")] AiConsentEntry? Current = null);

    private async Task<T> SendAsync<T>(HttpMethod method, string path, string? body, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(method, $"{_baseUrl()}{path}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", await _token());
        foreach (var (name, value) in _clientHeaders)
            request.Headers.Add(name, value);
        if (body is not null)
            request.Content = new StringContent(body, Encoding.UTF8, "application/json");
        _attachBinding?.Invoke(request);

        using var response = await _http.SendAsync(request, cancellationToken);
        var text = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
            throw new ConsentRequestException((int)response.StatusCode, RecordingConsent.ReadError(text)?.Code);

        try
        {
            return JsonSerializer.Deserialize<T>(text)
                ?? throw new ConsentRequestException((int)response.StatusCode, null);
        }
        catch (JsonException)
        {
            throw new ConsentRequestException((int)response.StatusCode, null);
        }
    }
}

/// <summary>
/// A non-2xx (or unreadable) response from a consent request. Carries no PHI: a
/// status and the backend's <c>error.code</c>, so the app can route a 401 to
/// re-auth.
/// </summary>
public sealed class ConsentRequestException(int statusCode, string? code)
    : Exception($"consent request failed: HTTP {statusCode}" + (code is null ? "" : $" [{code}]"))
{
    public int StatusCode { get; } = statusCode;
    public string? Code { get; } = code;
}
