using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace PabloCompanion.Core;

/// <summary>
/// The real session audio-upload wire path, shared by the shipping WinUI app and
/// the headless end-to-end runner so neither can drift from the other.
///
/// It owns exactly the pieces a reimplementation would get subtly wrong: the
/// <c>multipart/form-data</c> body (<c>therapist_audio</c> / <c>client_audio</c>
/// fields), the WAV header wrap that makes the audio self-describing, the device
/// binding attach, and the <c>INVALID_STATUS</c> → <c>recording_complete</c>
/// self-heal.
///
/// Auth and device binding are injected so the same code runs under the app's
/// credential-vault identity and under the runner's ephemeral software test key.
/// That injection is also what keeps this assembly free of WinRT: nothing here
/// touches <c>PasswordVault</c>.
///
/// The C# mirror of macOS <c>CompanionSessionCore.AudioUploadClient</c>.
/// </summary>
public sealed class AudioUploadClient
{
    /// <summary>The status a session must reach before the backend accepts its audio.</summary>
    public const string RecordingCompleteStatus = "recording_complete";

    /// <summary>Sample rate the capture path records at, and the rate stamped into the WAV headers.</summary>
    public const int DefaultSampleRate = 48000;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
    };

    private readonly Func<string> _baseUrl;
    private readonly Func<Task<string>> _token;
    private readonly Action<HttpRequestMessage>? _attachBinding;
    private readonly IReadOnlyDictionary<string, string> _clientHeaders;
    private readonly HttpClient _http;
    private readonly Action<string>? _log;

    /// <param name="baseUrl">Supplies the backend origin (no trailing slash). A delegate, not a
    /// string, because the app rediscovers its backend at sign-in and the client must follow.</param>
    /// <param name="token">Supplies a fresh Bearer token per request.</param>
    /// <param name="attachBinding">Stamps device-binding headers (<c>DPoP</c> + <c>X-Install-ID</c>)
    /// onto a request, or neither when unenrolled. Multipart requests are hand-built here rather
    /// than routed through the app's JSON request builder, so the binding must be attached on this
    /// seam explicitly.</param>
    /// <param name="clientHeaders">Client identification headers (<c>X-Client-Type</c> etc.).</param>
    /// <param name="http">HttpClient to send on. Defaults to a private instance.</param>
    /// <param name="log">Optional sink for the self-heal breadcrumbs.</param>
    public AudioUploadClient(
        Func<string> baseUrl,
        Func<Task<string>> token,
        Action<HttpRequestMessage>? attachBinding = null,
        IReadOnlyDictionary<string, string>? clientHeaders = null,
        HttpClient? http = null,
        Action<string>? log = null)
    {
        ArgumentNullException.ThrowIfNull(baseUrl);
        ArgumentNullException.ThrowIfNull(token);

        _baseUrl = baseUrl;
        _token = token;
        _attachBinding = attachBinding;
        _clientHeaders = clientHeaders ?? new Dictionary<string, string>();
        _http = http ?? new HttpClient();
        _log = log;
    }

    /// <summary>
    /// Uploads therapist (mic) and optional client (system) audio to
    /// <c>POST /api/sessions/{id}/upload-audio</c> as <c>multipart/form-data</c>.
    ///
    /// The sidecars are headerless PCM — mic mono, system stereo — so each part is
    /// given an accurate WAV header on the way out. Anything already carrying a
    /// RIFF header is sent untouched.
    ///
    /// The session must already be in <see cref="RecordingCompleteStatus"/>; if it
    /// isn't, the backend returns <c>400 INVALID_STATUS</c> and
    /// <see cref="UploadWithSelfHealAsync"/> is the entry point that recovers.
    /// </summary>
    public async Task<AudioUploadResponse> UploadAudioAsync(
        string sessionId,
        string therapistAudioPath,
        string? clientAudioPath = null,
        int sampleRate = DefaultSampleRate,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sessionId);
        ArgumentException.ThrowIfNullOrWhiteSpace(therapistAudioPath);

        var url = $"{_baseUrl()}/api/sessions/{Uri.EscapeDataString(sessionId)}/upload-audio";

        using var content = new MultipartFormDataContent();
        content.Add(
            BuildAudioContent(therapistAudioPath, sampleRate, channels: 1),
            "therapist_audio",
            WavFileName(therapistAudioPath));

        if (!string.IsNullOrEmpty(clientAudioPath) && File.Exists(clientAudioPath))
        {
            content.Add(
                BuildAudioContent(clientAudioPath, sampleRate, channels: 2),
                "client_audio",
                WavFileName(clientAudioPath));
        }

        using var request = new HttpRequestMessage(HttpMethod.Post, url) { Content = content };
        await AuthorizeAsync(request);

        using var response = await _http.SendAsync(request, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);

        if (!response.IsSuccessStatusCode)
            throw BuildError((int)response.StatusCode, body);

        return JsonSerializer.Deserialize<AudioUploadResponse>(body, JsonOptions)
            ?? throw new SessionUploadException(
                (int)response.StatusCode, null, "Failed to parse audio upload response");
    }

    /// <summary>
    /// Uploads audio, healing a <c>400 INVALID_STATUS</c> rejection once.
    ///
    /// The backend rejects the upload while the session is still <c>recording</c> —
    /// typically a session whose status PATCH never landed. The heal PATCHes it to
    /// <paramref name="recoveryStatus"/> and retries the upload a single time. Any
    /// other error, and any failure during the heal itself, propagates unchanged so
    /// the caller's own retry/backoff policy takes over.
    /// </summary>
    public async Task<AudioUploadResponse> UploadWithSelfHealAsync(
        string sessionId,
        string therapistAudioPath,
        string? clientAudioPath = null,
        int sampleRate = DefaultSampleRate,
        string recoveryStatus = RecordingCompleteStatus,
        CancellationToken cancellationToken = default)
    {
        try
        {
            return await UploadAudioAsync(
                sessionId, therapistAudioPath, clientAudioPath, sampleRate, cancellationToken);
        }
        catch (SessionUploadException ex) when (ex.IsInvalidStatus)
        {
            _log?.Invoke($"  upload 400 INVALID_STATUS session={sessionId} — attempting self-heal");
            await UpdateSessionStatusAsync(sessionId, recoveryStatus, cancellationToken);
            var response = await UploadAudioAsync(
                sessionId, therapistAudioPath, clientAudioPath, sampleRate, cancellationToken);
            _log?.Invoke($"  upload OK session={sessionId} (self-healed)");
            return response;
        }
    }

    /// <summary>
    /// PATCHes <c>/api/sessions/{id}/status</c> to <paramref name="status"/> (raw wire value).
    /// </summary>
    public async Task UpdateSessionStatusAsync(
        string sessionId,
        string status,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sessionId);

        var url = $"{_baseUrl()}/api/sessions/{Uri.EscapeDataString(sessionId)}/status";
        using var request = new HttpRequestMessage(HttpMethod.Patch, url)
        {
            Content = new StringContent(
                JsonSerializer.Serialize(new { status }), Encoding.UTF8, "application/json"),
        };
        await AuthorizeAsync(request);

        using var response = await _http.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            var body = await response.Content.ReadAsStringAsync(cancellationToken);
            throw BuildError((int)response.StatusCode, body);
        }
    }

    // --- Private helpers ---

    private async Task AuthorizeAsync(HttpRequestMessage request)
    {
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", await _token());
        foreach (var (name, value) in _clientHeaders)
            request.Headers.Add(name, value);
        _attachBinding?.Invoke(request);
    }

    /// <summary>
    /// Wraps a headerless PCM sidecar in an accurate WAV header, streaming the
    /// payload rather than buffering it; passes through anything already RIFF.
    /// </summary>
    private static HttpContent BuildAudioContent(string path, int sampleRate, int channels)
    {
        HttpContent content = StartsWithRiff(path)
            ? new StreamContent(File.OpenRead(path))
            : new WavStreamContent(path, sampleRate, channels);
        content.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
        return content;
    }

    private static bool StartsWithRiff(string path)
    {
        using var stream = File.OpenRead(path);
        Span<byte> prefix = stackalloc byte[4];
        var read = stream.ReadAtLeast(prefix, prefix.Length, throwOnEndOfStream: false);
        return WAVEncoder.IsRiff(prefix[..read]);
    }

    /// <summary>Names the uploaded part <c>.wav</c> — the bytes now carry a real WAV header.</summary>
    private static string WavFileName(string path) =>
        Path.ChangeExtension(Path.GetFileName(path), ".wav");

    private static SessionUploadException BuildError(int statusCode, string body)
    {
        var (message, code) = SessionUploadException.ParseEnvelope(body);
        return new SessionUploadException(
            statusCode,
            code,
            message ?? (string.IsNullOrWhiteSpace(body) ? $"HTTP {statusCode}" : body));
    }
}
