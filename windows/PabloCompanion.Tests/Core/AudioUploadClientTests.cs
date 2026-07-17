using System.Buffers.Binary;
using System.Net;
using System.Text;
using PabloCompanion.Core;

namespace PabloCompanion.Tests.Core;

/// <summary>
/// Covers the shared session upload wire path against a stubbed transport: the
/// multipart shape, the WAV header wrap that makes the audio self-describing, and
/// the <c>INVALID_STATUS</c> self-heal.
///
/// The self-heal tests here replace the ones that used to sit on
/// <c>TranscriptionViewModel</c>: the heal moved below the APIClient boundary into
/// this client, so it's now exercised where it lives — against real request bytes
/// rather than a stubbed APIClient method.
/// </summary>
public class AudioUploadClientTests : IDisposable
{
    private readonly string _tempDir;

    public AudioUploadClientTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"upload_test_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_tempDir);
    }

    public void Dispose()
    {
        GC.SuppressFinalize(this);
        if (Directory.Exists(_tempDir))
            Directory.Delete(_tempDir, recursive: true);
    }

    private const string OkBody =
        """{"id":"session-1","status":"recording_complete","queue":"transcribe","message":"ok"}""";

    private const string InvalidStatusBody =
        """{"error":{"code":"INVALID_STATUS","message":"Session must be in recording_complete"}}""";

    private string WritePcm(string name, int byteCount)
    {
        var path = Path.Combine(_tempDir, name);
        var pcm = new byte[byteCount];
        for (int i = 0; i < byteCount; i++) pcm[i] = (byte)(i % 251);
        File.WriteAllBytes(path, pcm);
        return path;
    }

    private AudioUploadClient MakeClient(StubHandler handler, Action<HttpRequestMessage>? binding = null) =>
        new(baseUrl: () => "https://api.example.test",
            token: () => Task.FromResult("test-token"),
            attachBinding: binding,
            clientHeaders: new Dictionary<string, string> { ["X-Client-Type"] = "test/1.0" },
            http: new HttpClient(handler));

    [Fact]
    public async Task Upload_PostsBothPartsToTheSessionUploadRoute()
    {
        var handler = new StubHandler().Respond(HttpStatusCode.OK, OkBody);
        var client = MakeClient(handler);

        var response = await client.UploadAudioAsync(
            "session-1", WritePcm("mic.pcm", 400), WritePcm("system.pcm", 800));

        Assert.Equal("session-1", response.Id);
        var request = Assert.Single(handler.Requests);
        Assert.Equal(HttpMethod.Post, request.Method);
        Assert.Equal("https://api.example.test/api/sessions/session-1/upload-audio", request.Url);
        // MultipartFormDataContent emits these unquoted (name=x, filename=y).
        Assert.Contains("name=therapist_audio", request.BodyText);
        Assert.Contains("name=client_audio", request.BodyText);
        Assert.Equal("Bearer test-token", request.Authorization);
        Assert.Equal("test/1.0", request.Header("X-Client-Type"));
    }

    [Fact]
    public async Task Upload_WrapsTherapistAudioAsMonoAndClientAudioAsStereo()
    {
        // The whole point of the wrap. Uploaded headerless, the backend guesses
        // stereo for both — halving the mono mic's frames and mangling it into
        // something that transcribes to nothing.
        var handler = new StubHandler().Respond(HttpStatusCode.OK, OkBody);
        var client = MakeClient(handler);

        await client.UploadAudioAsync("session-1", WritePcm("mic.pcm", 400), WritePcm("system.pcm", 800));

        var body = handler.Requests[0].Body;
        Assert.Equal(1, ChannelsOfPartAudio(body, "therapist_audio"));
        Assert.Equal(2, ChannelsOfPartAudio(body, "client_audio"));
        Assert.Equal(48000u, SampleRateOfPartAudio(body, "therapist_audio"));
        Assert.Equal(48000u, SampleRateOfPartAudio(body, "client_audio"));
    }

    [Fact]
    public async Task Upload_HeaderDeclaresTheActualPayloadLength()
    {
        var handler = new StubHandler().Respond(HttpStatusCode.OK, OkBody);
        var client = MakeClient(handler);

        await client.UploadAudioAsync("session-1", WritePcm("mic.pcm", 400));

        var body = handler.Requests[0].Body;
        var riff = IndexOfRiffAfterPart(body, "therapist_audio");
        Assert.Equal(400u, BinaryPrimitives.ReadUInt32LittleEndian(body.AsSpan(riff + 40, 4)));
        Assert.Equal(436u, BinaryPrimitives.ReadUInt32LittleEndian(body.AsSpan(riff + 4, 4))); // 36 + 400
    }

    [Fact]
    public async Task Upload_PartIsNamedWavSinceTheBytesNowCarryAHeader()
    {
        var handler = new StubHandler().Respond(HttpStatusCode.OK, OkBody);
        var client = MakeClient(handler);

        await client.UploadAudioAsync("session-1", WritePcm("recording_mic.pcm", 100));

        Assert.Contains("filename=recording_mic.wav", handler.Requests[0].BodyText);
    }

    [Fact]
    public async Task Upload_AlreadyRiffAudioIsSentUntouched()
    {
        var wav = Path.Combine(_tempDir, "already.wav");
        File.WriteAllBytes(wav, WAVEncoder.Wrap(new byte[200], 48000, 1));
        var handler = new StubHandler().Respond(HttpStatusCode.OK, OkBody);
        var client = MakeClient(handler);

        await client.UploadAudioAsync("session-1", wav);

        // Exactly one RIFF in the part: a second would mean the header got wrapped
        // around a file that already had one, corrupting the audio.
        var body = handler.Requests[0].Body;
        Assert.Equal(1, CountOccurrences(body, "RIFF"u8));
    }

    [Fact]
    public async Task Upload_OmitsClientPartWhenThereIsNoSystemAudio()
    {
        var handler = new StubHandler().Respond(HttpStatusCode.OK, OkBody);
        var client = MakeClient(handler);

        await client.UploadAudioAsync("session-1", WritePcm("mic.pcm", 100), clientAudioPath: null);

        Assert.Contains("name=therapist_audio", handler.Requests[0].BodyText);
        Assert.DoesNotContain("name=client_audio", handler.Requests[0].BodyText);
    }

    [Fact]
    public async Task Upload_AttachesInjectedDeviceBinding()
    {
        var handler = new StubHandler().Respond(HttpStatusCode.OK, OkBody);
        var client = MakeClient(handler, binding: request =>
        {
            request.Headers.Add("DPoP", "proof-jws");
            request.Headers.Add("X-Install-ID", "install-123");
        });

        await client.UploadAudioAsync("session-1", WritePcm("mic.pcm", 100));

        Assert.Equal("proof-jws", handler.Requests[0].Header("DPoP"));
        Assert.Equal("install-123", handler.Requests[0].Header("X-Install-ID"));
    }

    [Fact]
    public async Task Upload_NonSuccess_ThrowsWithParsedEnvelopeCode()
    {
        var handler = new StubHandler().Respond(HttpStatusCode.BadRequest, InvalidStatusBody);
        var client = MakeClient(handler);

        var ex = await Assert.ThrowsAsync<SessionUploadException>(
            () => client.UploadAudioAsync("session-1", WritePcm("mic.pcm", 100)));

        Assert.Equal(400, ex.StatusCode);
        Assert.Equal("INVALID_STATUS", ex.ErrorCode);
        Assert.True(ex.IsInvalidStatus);
    }

    // --- self-heal ---

    [Fact]
    public async Task SelfHeal_OnInvalidStatus_PatchesThenRetriesUpload()
    {
        // A session whose status PATCH never landed is still "recording" server-side
        // and rejects its audio forever without this heal.
        var handler = new StubHandler()
            .Respond(HttpStatusCode.BadRequest, InvalidStatusBody)  // first upload
            .Respond(HttpStatusCode.OK, "{}")                       // recovery PATCH
            .Respond(HttpStatusCode.OK, OkBody);                    // retried upload
        var client = MakeClient(handler);

        var response = await client.UploadWithSelfHealAsync("session-1", WritePcm("mic.pcm", 100));

        Assert.Equal("session-1", response.Id);
        Assert.Equal(3, handler.Requests.Count);

        var patch = handler.Requests[1];
        Assert.Equal(HttpMethod.Patch, patch.Method);
        Assert.Equal("https://api.example.test/api/sessions/session-1/status", patch.Url);
        Assert.Contains("recording_complete", patch.BodyText);

        Assert.Equal(HttpMethod.Post, handler.Requests[2].Method);
    }

    [Fact]
    public async Task SelfHeal_WhenRecoveryPatchFails_PropagatesAndDoesNotRetryUpload()
    {
        var handler = new StubHandler()
            .Respond(HttpStatusCode.BadRequest, InvalidStatusBody)          // first upload
            .Respond(HttpStatusCode.InternalServerError, "patch exploded"); // recovery PATCH
        var client = MakeClient(handler);

        var ex = await Assert.ThrowsAsync<SessionUploadException>(
            () => client.UploadWithSelfHealAsync("session-1", WritePcm("mic.pcm", 100)));

        Assert.Equal(500, ex.StatusCode);
        // Upload, PATCH — and no second upload. The caller's backoff takes over.
        Assert.Equal(2, handler.Requests.Count);
    }

    [Fact]
    public async Task SelfHeal_OnUnrelatedError_DoesNotPatch()
    {
        var handler = new StubHandler().Respond(HttpStatusCode.InternalServerError, "boom");
        var client = MakeClient(handler);

        var ex = await Assert.ThrowsAsync<SessionUploadException>(
            () => client.UploadWithSelfHealAsync("session-1", WritePcm("mic.pcm", 100)));

        Assert.Equal(500, ex.StatusCode);
        Assert.Single(handler.Requests);
    }

    [Fact]
    public async Task SelfHeal_HappyPath_DoesNotPatch()
    {
        var handler = new StubHandler().Respond(HttpStatusCode.OK, OkBody);
        var client = MakeClient(handler);

        await client.UploadWithSelfHealAsync("session-1", WritePcm("mic.pcm", 100));

        Assert.Single(handler.Requests);
        Assert.Equal(HttpMethod.Post, handler.Requests[0].Method);
    }

    [Fact]
    public async Task SelfHeal_RetriedUploadStillCarriesWavHeaders()
    {
        // Regression guard: the heal re-sends the body, and a stream consumed by the
        // first attempt would leave the retry with truncated or headerless audio.
        var handler = new StubHandler()
            .Respond(HttpStatusCode.BadRequest, InvalidStatusBody)
            .Respond(HttpStatusCode.OK, "{}")
            .Respond(HttpStatusCode.OK, OkBody);
        var client = MakeClient(handler);

        await client.UploadWithSelfHealAsync(
            "session-1", WritePcm("mic.pcm", 400), WritePcm("system.pcm", 800));

        var retried = handler.Requests[2].Body;
        Assert.Equal(1, ChannelsOfPartAudio(retried, "therapist_audio"));
        Assert.Equal(2, ChannelsOfPartAudio(retried, "client_audio"));
        Assert.Equal(400u, BinaryPrimitives.ReadUInt32LittleEndian(
            retried.AsSpan(IndexOfRiffAfterPart(retried, "therapist_audio") + 40, 4)));
    }

    // --- multipart byte helpers ---

    /// <summary>Finds the RIFF header belonging to the named multipart field.</summary>
    private static int IndexOfRiffAfterPart(byte[] body, string fieldName)
    {
        var marker = IndexOf(body, Encoding.ASCII.GetBytes($"name={fieldName}"), 0);
        Assert.True(marker >= 0, $"multipart body has no {fieldName} part");
        var riff = IndexOf(body, "RIFF"u8.ToArray(), marker);
        Assert.True(riff >= 0, $"{fieldName} part carries no RIFF header");
        return riff;
    }

    private static int ChannelsOfPartAudio(byte[] body, string fieldName) =>
        BinaryPrimitives.ReadUInt16LittleEndian(body.AsSpan(IndexOfRiffAfterPart(body, fieldName) + 22, 2));

    private static uint SampleRateOfPartAudio(byte[] body, string fieldName) =>
        BinaryPrimitives.ReadUInt32LittleEndian(body.AsSpan(IndexOfRiffAfterPart(body, fieldName) + 24, 4));

    private static int CountOccurrences(byte[] haystack, ReadOnlySpan<byte> needle)
    {
        var pattern = needle.ToArray();
        int count = 0, from = 0;
        while (true)
        {
            var found = IndexOf(haystack, pattern, from);
            if (found < 0) return count;
            count++;
            from = found + 1;
        }
    }

    private static int IndexOf(byte[] haystack, byte[] needle, int start)
    {
        for (int i = start; i <= haystack.Length - needle.Length; i++)
        {
            var match = true;
            for (int j = 0; j < needle.Length; j++)
            {
                if (haystack[i + j] != needle[j]) { match = false; break; }
            }
            if (match) return i;
        }
        return -1;
    }

    // --- transport stub ---

    private sealed record RecordedRequest(
        HttpMethod Method,
        string Url,
        byte[] Body,
        string? Authorization,
        Dictionary<string, string> Headers)
    {
        public string BodyText => Encoding.Latin1.GetString(Body);
        public string? Header(string name) => Headers.GetValueOrDefault(name);
    }

    /// <summary>Replays queued responses in order, recording each request's real bytes.</summary>
    private sealed class StubHandler : HttpMessageHandler
    {
        private readonly Queue<(HttpStatusCode Status, string Body)> _responses = new();

        public List<RecordedRequest> Requests { get; } = [];

        public StubHandler Respond(HttpStatusCode status, string body)
        {
            _responses.Enqueue((status, body));
            return this;
        }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            // Reading the content here is what drives WavStreamContent's serialize
            // path, so the recorded bytes are exactly what would go on the wire.
            var body = request.Content is null
                ? []
                : await request.Content.ReadAsByteArrayAsync(cancellationToken);

            Requests.Add(new RecordedRequest(
                request.Method,
                request.RequestUri!.ToString(),
                body,
                request.Headers.Authorization?.ToString(),
                request.Headers.ToDictionary(h => h.Key, h => string.Join(",", h.Value))));

            Assert.True(_responses.Count > 0, $"unexpected request: {request.Method} {request.RequestUri}");
            var (status, responseBody) = _responses.Dequeue();
            return new HttpResponseMessage(status) { Content = new StringContent(responseBody) };
        }
    }
}
