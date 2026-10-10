using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace PabloCompanion.Core;

/// <summary>
/// The real session audio-upload wire path, shared by the shipping WinUI app and
/// the headless end-to-end runner so neither can drift from the other.
///
/// It owns exactly the pieces a reimplementation would get subtly wrong: the
/// signed-URL flow (init, one direct-to-storage PUT per channel replaying the
/// signed headers exactly, finalize), the WAV header wrap that makes raw PCM
/// self-describing, the device binding attach, and the <c>INVALID_STATUS</c> →
/// <c>recording_complete</c> self-heal. The older single multipart POST
/// (<see cref="UploadAudioAsync"/>) is kept but no longer called: the load
/// balancer in front of the backend rejects it past ~32 MiB.
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
    private readonly HttpClient _storageHttp;
    private readonly TimeSpan _putStallTimeout;
    private readonly Action<string>? _log;

    /// <summary>
    /// How long a storage PUT may go without moving a byte before it is abandoned.
    /// The PUT itself has no overall deadline (see the constructor), so this is
    /// what stops a dead connection from hanging an upload forever.
    /// </summary>
    public static readonly TimeSpan DefaultPutStallTimeout = TimeSpan.FromMinutes(2);

    /// <summary>File suffix capture gives an encrypted sidecar.</summary>
    public const string EncryptedSidecarSuffix = ".enc.pcm";

    /// <param name="baseUrl">Supplies the backend origin (no trailing slash). A delegate, not a
    /// string, because the app rediscovers its backend at sign-in and the client must follow.</param>
    /// <param name="token">Supplies a fresh Bearer token per request.</param>
    /// <param name="attachBinding">Stamps device-binding headers (<c>DPoP</c> + <c>X-Install-ID</c>)
    /// onto a request, or neither when unenrolled. Multipart requests are hand-built here rather
    /// than routed through the app's JSON request builder, so the binding must be attached on this
    /// seam explicitly.</param>
    /// <param name="clientHeaders">Client identification headers (<c>X-Client-Type</c> etc.).</param>
    /// <param name="http">HttpClient for the backend calls. Defaults to a private instance.</param>
    /// <param name="log">Optional sink for upload breadcrumbs (never audio or patient data).</param>
    /// <param name="storageHttp">HttpClient for the direct-to-storage PUTs. Defaults to a private
    /// instance with no overall timeout: HttpClient's default 100 s would cancel a several-hundred-MB
    /// PUT on a home uplink part-way through, every time. <paramref name="putStallTimeout"/> bounds
    /// a PUT that stops making progress instead.</param>
    /// <param name="putStallTimeout">How long a PUT may send nothing before it is abandoned.
    /// Defaults to <see cref="DefaultPutStallTimeout"/>.</param>
    public AudioUploadClient(
        Func<string> baseUrl,
        Func<Task<string>> token,
        Action<HttpRequestMessage>? attachBinding = null,
        IReadOnlyDictionary<string, string>? clientHeaders = null,
        HttpClient? http = null,
        Action<string>? log = null,
        HttpClient? storageHttp = null,
        TimeSpan? putStallTimeout = null)
    {
        ArgumentNullException.ThrowIfNull(baseUrl);
        ArgumentNullException.ThrowIfNull(token);

        _baseUrl = baseUrl;
        _token = token;
        _attachBinding = attachBinding;
        _clientHeaders = clientHeaders ?? new Dictionary<string, string>();
        _http = http ?? new HttpClient();
        _storageHttp = storageHttp ?? new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        _putStallTimeout = putStallTimeout ?? DefaultPutStallTimeout;
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
    /// The shared upload entry point for the app and the headless runner: both
    /// channels go straight to storage through signed URLs, healing a
    /// <c>400 INVALID_STATUS</c> at finalize once.
    ///
    /// Why signed URLs and not the multipart POST: a full-length session is hundreds
    /// of megabytes, and the load balancer in front of the backend rejects a request
    /// that size (413) before it reaches the app. Here only two small JSON calls
    /// (init and finalize) go through it; the audio goes to storage directly.
    ///
    /// Flow: <see cref="InitSignedUploadAsync"/> (Bearer + device binding) mints a
    /// signed recipe per channel → <see cref="PutChannelUnlessStoredAsync"/> sends
    /// each channel to storage, streamed from disk (decrypted on the fly when the
    /// sidecar is encrypted), skipping one an earlier attempt already stored →
    /// <see cref="FinalizeAsync"/> verifies both objects and starts transcription.
    ///
    /// The heal: finalize rejects a session still in <c>recording</c> (one whose
    /// status PATCH never landed). It is PATCHed to <paramref name="recoveryStatus"/>
    /// and finalized once more. The audio is already in storage by then, so the heal
    /// never re-sends it. Any other error, and any failure during the heal itself,
    /// propagates unchanged so the caller's retry/backoff policy takes over.
    /// </summary>
    /// <param name="sessionId">Session the audio belongs to.</param>
    /// <param name="therapistAudioPath">Mic sidecar (mono).</param>
    /// <param name="clientAudioPath">System-audio sidecar (stereo). Required: finalize verifies
    /// both objects, so a missing channel fails here, before any backend round-trip.</param>
    /// <param name="sampleRate">Frames per second the recording was captured at; stamped into the
    /// WAV header of a raw PCM channel.</param>
    /// <param name="recoveryStatus">Status the heal PATCHes a still-recording session to.</param>
    /// <param name="decryptChunk">Decrypts one AES-GCM sidecar chunk. Required when either path is
    /// an encrypted sidecar (<see cref="EncryptedSidecarSuffix"/>).</param>
    /// <param name="cancellationToken">Cancels the whole upload.</param>
    public async Task<AudioUploadResponse> UploadWithSelfHealAsync(
        string sessionId,
        string therapistAudioPath,
        string? clientAudioPath = null,
        int sampleRate = DefaultSampleRate,
        string recoveryStatus = RecordingCompleteStatus,
        Func<byte[], byte[]>? decryptChunk = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sessionId);
        ArgumentException.ThrowIfNullOrWhiteSpace(therapistAudioPath);

        if (!File.Exists(therapistAudioPath))
            throw new SessionUploadException(-1, null, "Therapist audio channel is missing");

        // Capture always writes a system channel next to the mic, and finalize 400s
        // if either object is missing — so fail now, not opaquely after init and a
        // full therapist PUT.
        if (string.IsNullOrEmpty(clientAudioPath) || !File.Exists(clientAudioPath))
        {
            throw new SessionUploadException(
                -1, null, "Signed-URL upload requires both therapist and client audio channels");
        }

        // Fail closed before minting anything: without a key there is no way to
        // send the audio, and that must surface as a retryable failure.
        RequireDecryptorFor(therapistAudioPath, decryptChunk);
        RequireDecryptorFor(clientAudioPath, decryptChunk);

        var init = await InitSignedUploadAsync(sessionId, cancellationToken);

        await PutChannelUnlessStoredAsync(
            init.Therapist, therapistAudioPath, sampleRate, channels: 1, decryptChunk,
            label: "therapist", cancellationToken);
        await PutChannelUnlessStoredAsync(
            init.Client, clientAudioPath, sampleRate, channels: 2, decryptChunk,
            label: "client", cancellationToken);

        try
        {
            return await FinalizeAsync(sessionId, cancellationToken);
        }
        catch (SessionUploadException ex) when (ex.IsInvalidStatus)
        {
            _log?.Invoke($"  finalize 400 INVALID_STATUS session={sessionId} — attempting self-heal");
            await UpdateSessionStatusAsync(sessionId, recoveryStatus, cancellationToken);
            var response = await FinalizeAsync(sessionId, cancellationToken);
            _log?.Invoke($"  finalize OK session={sessionId} (self-healed)");
            return response;
        }
    }

    /// <summary>
    /// <c>POST /api/sessions/{id}/upload-audio/init</c>: mints one signed
    /// direct-to-storage recipe per channel.
    /// </summary>
    public async Task<AudioUploadInitResponse> InitSignedUploadAsync(
        string sessionId, CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sessionId);

        var body = await PostBackendAsync(sessionId, "upload-audio/init", cancellationToken);
        return JsonSerializer.Deserialize<AudioUploadInitResponse>(body, JsonOptions)
            ?? throw new SessionUploadException(-1, null, "Failed to parse upload init response");
    }

    /// <summary>
    /// Sends one channel to storage using its signed recipe — unless an earlier
    /// attempt already stored exactly these bytes.
    ///
    /// On a slow link, re-sending a channel that landed last time is most of what
    /// keeps a long session's retries from ever finishing. Only an exact size match
    /// counts as stored: anything else is sent, overwriting what is there.
    /// </summary>
    /// <returns>True if the channel was sent, false if it was already stored.</returns>
    public async Task<bool> PutChannelUnlessStoredAsync(
        AudioUploadInitChannel channel,
        string path,
        int sampleRate,
        int channels,
        Func<byte[], byte[]>? decryptChunk,
        string label,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(channel);
        ArgumentException.ThrowIfNullOrWhiteSpace(path);

        using var content = BuildChannelContent(path, sampleRate, channels, decryptChunk);
        var length = content.Headers.ContentLength
            ?? throw new InvalidOperationException("Channel content must know its length.");

        if (length <= WAVEncoder.HeaderSize)
        {
            // Loopback can deliver nothing (no other party audible, or a device that
            // never produced a buffer). Still send the header-only WAV so finalize has
            // both objects and the therapist audio produces a note.
            _log?.Invoke($"  WARN {label} channel has no audio; sending header-only WAV");
        }

        if (channel.ExistingBytes == length)
        {
            _log?.Invoke($"  {label} channel already in storage; skipping PUT");
            return false;
        }

        await PutAsync(channel.Upload, content, label, cancellationToken);
        _log?.Invoke($"  PUT {label} channel to storage ({length} bytes)");
        return true;
    }

    /// <summary>
    /// <c>POST /api/sessions/{id}/upload-audio/finalize</c>: the backend verifies
    /// both stored objects and queues transcription.
    /// </summary>
    public async Task<AudioUploadResponse> FinalizeAsync(
        string sessionId, CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sessionId);

        var body = await PostBackendAsync(sessionId, "upload-audio/finalize", cancellationToken);
        return JsonSerializer.Deserialize<AudioUploadResponse>(body, JsonOptions)
            ?? throw new SessionUploadException(-1, null, "Failed to parse upload finalize response");
    }

    /// <summary>
    /// Builds the exact body a channel's PUT sends, with a known length.
    ///
    /// Encrypted sidecars decrypt on the fly (<see cref="EncryptedPcmWavContent"/>);
    /// plaintext raw PCM gets a WAV header (<see cref="WavStreamContent"/>); audio
    /// that already describes itself (RIFF WAV, ADTS AAC) goes through unchanged.
    /// No Content-Type is set here: the signed headers decide it.
    /// </summary>
    internal static HttpContent BuildChannelContent(
        string path, int sampleRate, int channels, Func<byte[], byte[]>? decryptChunk)
    {
        if (IsEncryptedSidecar(path))
        {
            RequireDecryptorFor(path, decryptChunk);
            return new EncryptedPcmWavContent(path, sampleRate, channels, decryptChunk!);
        }

        return StartsSelfDescribing(path)
            ? new StreamContent(OpenForStreaming(path))
            : new WavStreamContent(path, sampleRate, channels);
    }

    /// <summary>Whether <paramref name="path"/> names an encrypted capture sidecar.</summary>
    public static bool IsEncryptedSidecar(string path) =>
        path.EndsWith(EncryptedSidecarSuffix, StringComparison.OrdinalIgnoreCase);

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

    /// <summary>POSTs an empty authorized request to a session sub-route and returns the 2xx body.</summary>
    private async Task<string> PostBackendAsync(
        string sessionId, string route, CancellationToken cancellationToken)
    {
        var url = $"{_baseUrl()}/api/sessions/{Uri.EscapeDataString(sessionId)}/{route}";
        using var request = new HttpRequestMessage(HttpMethod.Post, url);
        await AuthorizeAsync(request);

        using var response = await _http.SendAsync(request, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
            throw BuildError((int)response.StatusCode, body);
        return body;
    }

    /// <summary>
    /// Sends one channel's body straight to storage with the signed recipe.
    ///
    /// No Bearer, no DPoP, no <c>X-Install-ID</c>, no client headers: the signed URL
    /// is the authorization, and storage checks the request against exactly the
    /// headers that were signed — adding, dropping or changing any of them is a
    /// <c>403 SignatureDoesNotMatch</c>. So the recipe's headers are replayed
    /// verbatim and nothing else is set.
    /// </summary>
    private async Task PutAsync(
        UploadTarget target, HttpContent body, string label, CancellationToken cancellationToken)
    {
        if (!Uri.TryCreate(target.Url, UriKind.Absolute, out var uri))
            throw new SessionUploadException(-1, null, $"Invalid {label} signed upload URL");

        // No overall deadline on the PUT; instead every write pushes the deadline
        // out, so only a PUT that stops moving bytes is abandoned.
        using var stall = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        stall.CancelAfter(_putStallTimeout);
        using var content = new ProgressGuardedContent(body, () => stall.CancelAfter(_putStallTimeout));

        using var request = new HttpRequestMessage(new HttpMethod(target.Method), uri) { Content = content };
        foreach (var (name, value) in target.Headers ?? new Dictionary<string, string>())
        {
            // Content-Type (and any other entity header) belongs on the content;
            // the request collection refuses those, which is how they're told apart.
            if (!request.Headers.TryAddWithoutValidation(name, value))
                content.Headers.TryAddWithoutValidation(name, value);
        }

        try
        {
            using var response = await _storageHttp.SendAsync(request, stall.Token);
            if (!response.IsSuccessStatusCode)
            {
                var responseBody = await response.Content.ReadAsStringAsync(stall.Token);
                throw BuildError((int)response.StatusCode, responseBody);
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new SessionUploadException(
                -1, null, $"Upload of the {label} channel stalled and was abandoned");
        }
    }

    /// <summary>Throws when <paramref name="path"/> is encrypted but there is no way to decrypt it.</summary>
    private static void RequireDecryptorFor(string path, Func<byte[], byte[]>? decryptChunk)
    {
        // Fail closed. Sending the ciphertext would hand storage bytes that are not
        // audio; the backend would accept them and the caller would treat the
        // session as uploaded. A missing key is transient and recoverable, so it
        // must surface as a failure the retry path holds onto.
        if (IsEncryptedSidecar(path) && decryptChunk is null)
        {
            throw new InvalidOperationException(
                "Cannot decrypt an encrypted recording for upload: no encryption key is available. "
                    + "The recording stays queued and will retry once a key can be resolved.");
        }
    }

    private static bool StartsSelfDescribing(string path)
    {
        using var stream = File.OpenRead(path);
        Span<byte> prefix = stackalloc byte[4];
        var read = stream.ReadAtLeast(prefix, prefix.Length, throwOnEndOfStream: false);
        return AudioFormat.IsSelfDescribing(prefix[..read]);
    }

    private static FileStream OpenForStreaming(string path) =>
        new(path, FileMode.Open, FileAccess.Read, FileShare.Read, bufferSize: 81920, useAsync: true);

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
