using System.Buffers.Binary;
using System.Net;
using System.Text;
using System.Text.Json;
using AudioCapture.Storage;
using PabloCompanion.Core;

namespace PabloCompanion.Tests.Core;

/// <summary>
/// Covers the shared session upload wire path against a stubbed transport: the
/// signed-URL flow (init, direct-to-storage PUTs, finalize), the encrypted
/// sidecar streamed without a plaintext copy, the WAV header wrap that makes raw
/// PCM self-describing (and its passthrough for audio that already is), the
/// <c>INVALID_STATUS</c> self-heal at finalize, and the retained multipart POST.
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
        _encryptor.Dispose();
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

    private static AudioUploadClient MakeClient(
        StubHandler handler, Action<HttpRequestMessage>? binding = null, Action<string>? log = null) =>
        new(baseUrl: () => "https://api.example.test",
            token: () => Task.FromResult("test-token"),
            attachBinding: binding,
            clientHeaders: new Dictionary<string, string> { ["X-Client-Type"] = "test/1.0" },
            http: new HttpClient(handler, disposeHandler: false),
            log: log,
            storageHttp: new HttpClient(handler, disposeHandler: false));

    // --- multipart POST (retained, no longer the production path) ---

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

    // --- signed-URL upload (the production path) ---

    private const string TherapistPutUrl = "https://storage.example.test/bucket/therapist.wav?X-Goog-Signature=t";
    private const string ClientPutUrl = "https://storage.example.test/bucket/client.wav?X-Goog-Signature=c";

    private static readonly Dictionary<string, string> SignedHeaders = new()
    {
        ["Content-Type"] = "audio/wav",
        ["x-goog-content-length-range"] = "0,2147483648",
    };

    private static string InitBody(long? therapistExisting = null, long? clientExisting = null)
    {
        static object Channel(string url, string path, long? existing) => new Dictionary<string, object?>
        {
            ["upload"] = new { url, method = "PUT", headers = SignedHeaders, fields = new { } },
            ["gcs_path"] = path,
            ["existing_bytes"] = existing,
        };
        return JsonSerializer.Serialize(new Dictionary<string, object>
        {
            ["session_id"] = "session-1",
            ["therapist"] = Channel(TherapistPutUrl, "audio/session-1/therapist.wav", therapistExisting),
            ["client"] = Channel(ClientPutUrl, "audio/session-1/client.wav", clientExisting),
            ["max_bytes"] = 2147483648L,
        });
    }

    [Fact]
    public async Task Signed_SendsInitThenBothPutsThenFinalize_InOrder()
    {
        var handler = new StubHandler()
            .Respond(HttpStatusCode.OK, InitBody())
            .Respond(HttpStatusCode.OK, "")
            .Respond(HttpStatusCode.OK, "")
            .Respond(HttpStatusCode.OK, OkBody);
        var client = MakeClient(handler);

        var response = await client.UploadWithSelfHealAsync(
            "session-1", WritePcm("mic.pcm", 400), WritePcm("system.pcm", 800));

        Assert.Equal("session-1", response.Id);
        Assert.Collection(
            handler.Requests,
            r => Assert.Equal(("POST", "https://api.example.test/api/sessions/session-1/upload-audio/init"), (r.Method.Method, r.Url)),
            r => Assert.Equal(("PUT", TherapistPutUrl), (r.Method.Method, r.Url)),
            r => Assert.Equal(("PUT", ClientPutUrl), (r.Method.Method, r.Url)),
            r => Assert.Equal(("POST", "https://api.example.test/api/sessions/session-1/upload-audio/finalize"), (r.Method.Method, r.Url)));

        // Init and finalize are ordinary authenticated backend calls.
        Assert.Equal("Bearer test-token", handler.Requests[0].Authorization);
        Assert.Equal("Bearer test-token", handler.Requests[3].Authorization);
        Assert.Equal("test/1.0", handler.Requests[3].Header("X-Client-Type"));

        // Each PUT is its channel as a WAV: mono mic, stereo system, exact sizes.
        var therapist = handler.Requests[1].Body;
        var system = handler.Requests[2].Body;
        Assert.Equal(44 + 400, therapist.Length);
        Assert.Equal(44 + 800, system.Length);
        Assert.Equal(1, BinaryPrimitives.ReadUInt16LittleEndian(therapist.AsSpan(22, 2)));
        Assert.Equal(2, BinaryPrimitives.ReadUInt16LittleEndian(system.AsSpan(22, 2)));
    }

    [Fact]
    public async Task Signed_InitAndFinalizeCarryDeviceBinding()
    {
        var handler = new StubHandler()
            .Respond(HttpStatusCode.OK, InitBody())
            .Respond(HttpStatusCode.OK, "")
            .Respond(HttpStatusCode.OK, "")
            .Respond(HttpStatusCode.OK, OkBody);
        var client = MakeClient(handler, binding: BindDevice);

        await client.UploadWithSelfHealAsync("session-1", WritePcm("mic.pcm", 100), WritePcm("system.pcm", 100));

        foreach (var backendCall in new[] { handler.Requests[0], handler.Requests[3] })
        {
            Assert.Equal("proof-jws", backendCall.Header("DPoP"));
            Assert.Equal("install-123", backendCall.Header("X-Install-ID"));
        }
    }

    [Fact]
    public async Task Signed_PutsCarryExactlyTheSignedHeadersAndNoCredentials()
    {
        // Storage checks the request against the headers that were signed. One
        // extra (or a changed Content-Type) is 403 SignatureDoesNotMatch; a Bearer
        // or DPoP proof sent to a third-party host is a credential leak.
        var handler = new StubHandler()
            .Respond(HttpStatusCode.OK, InitBody())
            .Respond(HttpStatusCode.OK, "")
            .Respond(HttpStatusCode.OK, "")
            .Respond(HttpStatusCode.OK, OkBody);
        var client = MakeClient(handler, binding: BindDevice);

        await client.UploadWithSelfHealAsync("session-1", WritePcm("mic.pcm", 100), WritePcm("system.pcm", 100));

        foreach (var put in handler.Requests.Where(r => r.Method == HttpMethod.Put))
        {
            Assert.Null(put.Authorization);
            Assert.Null(put.Header("Authorization"));
            Assert.Null(put.Header("DPoP"));
            Assert.Null(put.Header("X-Install-ID"));
            Assert.Null(put.Header("X-Client-Type"));

            // Content-Length is the transport's framing, not a signed header.
            var sent = put.AllHeaders
                .Where(h => !h.Key.Equals("Content-Length", StringComparison.OrdinalIgnoreCase))
                .ToDictionary(h => h.Key, h => h.Value);
            Assert.Equal(
                SignedHeaders.OrderBy(h => h.Key, StringComparer.OrdinalIgnoreCase),
                sent.OrderBy(h => h.Key, StringComparer.OrdinalIgnoreCase));
            Assert.Equal(put.Body.Length.ToString(), put.Header("Content-Length"));
        }
    }

    [Theory]
    [InlineData(44 + 100, 44 + 200, 0)]       // both already stored at the exact size: no PUTs
    [InlineData(44 + 100, null, 1)]           // therapist stored, client unknown: client only
    [InlineData(44 + 99, 44 + 200, 1)]        // therapist size differs: re-send therapist only
    [InlineData(null, null, 2)]               // older backend / first attempt: send both
    public async Task Signed_SkipsAPutOnlyWhenExistingBytesMatchesTheExactSize(
        int? therapistExisting, int? clientExisting, int expectedPuts)
    {
        var handler = new StubHandler().Respond(HttpStatusCode.OK, InitBody(therapistExisting, clientExisting));
        for (var i = 0; i < expectedPuts; i++) handler.Respond(HttpStatusCode.OK, "");
        handler.Respond(HttpStatusCode.OK, OkBody);
        var client = MakeClient(handler);

        await client.UploadWithSelfHealAsync("session-1", WritePcm("mic.pcm", 100), WritePcm("system.pcm", 200));

        Assert.Equal(expectedPuts, handler.Requests.Count(r => r.Method == HttpMethod.Put));
        Assert.EndsWith("/upload-audio/finalize", handler.Requests[^1].Url);
    }

    [Fact]
    public async Task Signed_MissingClientChannel_FailsBeforeInit()
    {
        var handler = new StubHandler();
        var client = MakeClient(handler);

        var ex = await Assert.ThrowsAsync<SessionUploadException>(
            () => client.UploadWithSelfHealAsync("session-1", WritePcm("mic.pcm", 100), clientAudioPath: null));

        Assert.Equal(-1, ex.StatusCode);
        Assert.Empty(handler.Requests);
    }

    [Fact]
    public async Task Signed_EncryptedSidecarWithoutAKey_FailsClosedBeforeInit()
    {
        var handler = new StubHandler();
        var client = MakeClient(handler);
        var mic = WriteEncrypted("mic.enc.pcm", Pattern(1000), chunkSize: 300);

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => client.UploadWithSelfHealAsync("session-1", mic, WritePcm("system.pcm", 100)));

        Assert.Empty(handler.Requests);
    }

    [Fact]
    public async Task Signed_EmptySystemSidecar_SendsHeaderOnlyWavAndWarns()
    {
        // Loopback can deliver nothing. The therapist audio must still make a note,
        // and finalize needs both objects, so the client channel is a valid empty WAV.
        var handler = new StubHandler()
            .Respond(HttpStatusCode.OK, InitBody())
            .Respond(HttpStatusCode.OK, "")
            .Respond(HttpStatusCode.OK, "")
            .Respond(HttpStatusCode.OK, OkBody);
        var log = new List<string>();
        var client = MakeClient(handler, log: log.Add);

        await client.UploadWithSelfHealAsync("session-1", WritePcm("mic.pcm", 100), WritePcm("system.pcm", 0));

        var clientPut = handler.Requests[2].Body;
        Assert.Equal(WAVEncoder.HeaderSize, clientPut.Length);
        Assert.Equal(0u, BinaryPrimitives.ReadUInt32LittleEndian(clientPut.AsSpan(40, 4)));
        Assert.Equal(2, BinaryPrimitives.ReadUInt16LittleEndian(clientPut.AsSpan(22, 2)));
        Assert.Contains(log, line => line.Contains("WARN client channel has no audio"));
    }

    [Fact]
    public async Task Signed_StampsTheRecordingsSampleRateIntoTheHeader()
    {
        var handler = new StubHandler()
            .Respond(HttpStatusCode.OK, InitBody())
            .Respond(HttpStatusCode.OK, "")
            .Respond(HttpStatusCode.OK, "")
            .Respond(HttpStatusCode.OK, OkBody);
        var client = MakeClient(handler);

        await client.UploadWithSelfHealAsync(
            "session-1", WritePcm("mic.pcm", 100), WritePcm("system.pcm", 100), sampleRate: 44100);

        Assert.Equal(44100u, BinaryPrimitives.ReadUInt32LittleEndian(handler.Requests[1].Body.AsSpan(24, 4)));
        Assert.Equal(44100u, BinaryPrimitives.ReadUInt32LittleEndian(handler.Requests[2].Body.AsSpan(24, 4)));
    }

    [Fact]
    public async Task Signed_StorageRejection_PropagatesAndDoesNotFinalize()
    {
        var handler = new StubHandler()
            .Respond(HttpStatusCode.OK, InitBody())
            .Respond(HttpStatusCode.Forbidden, "<Error><Code>SignatureDoesNotMatch</Code></Error>");
        var client = MakeClient(handler);

        var ex = await Assert.ThrowsAsync<SessionUploadException>(
            () => client.UploadWithSelfHealAsync("session-1", WritePcm("mic.pcm", 100), WritePcm("system.pcm", 100)));

        Assert.Equal(403, ex.StatusCode);
        Assert.Equal(2, handler.Requests.Count);
    }

    // --- self-heal (at finalize) ---

    [Fact]
    public async Task SelfHeal_OnInvalidStatusAtFinalize_PatchesThenFinalizesAgain_WithoutReSending()
    {
        // A session whose status PATCH never landed is still "recording" server-side
        // and rejects finalize forever without this heal. The audio is already in
        // storage, so the heal must not PUT it a second time.
        var handler = new StubHandler()
            .Respond(HttpStatusCode.OK, InitBody())
            .Respond(HttpStatusCode.OK, "")                         // PUT therapist
            .Respond(HttpStatusCode.OK, "")                         // PUT client
            .Respond(HttpStatusCode.BadRequest, InvalidStatusBody)  // finalize
            .Respond(HttpStatusCode.OK, "{}")                       // recovery PATCH
            .Respond(HttpStatusCode.OK, OkBody);                    // finalize again
        var client = MakeClient(handler);

        var response = await client.UploadWithSelfHealAsync(
            "session-1", WritePcm("mic.pcm", 100), WritePcm("system.pcm", 100));

        Assert.Equal("session-1", response.Id);
        Assert.Equal(6, handler.Requests.Count);
        Assert.Equal(2, handler.Requests.Count(r => r.Method == HttpMethod.Put));

        var patch = handler.Requests[4];
        Assert.Equal(HttpMethod.Patch, patch.Method);
        Assert.Equal("https://api.example.test/api/sessions/session-1/status", patch.Url);
        Assert.Contains("recording_complete", patch.BodyText);

        Assert.EndsWith("/upload-audio/finalize", handler.Requests[5].Url);
    }

    [Fact]
    public async Task SelfHeal_WhenRecoveryPatchFails_PropagatesAndDoesNotFinalizeAgain()
    {
        var handler = new StubHandler()
            .Respond(HttpStatusCode.OK, InitBody())
            .Respond(HttpStatusCode.OK, "")
            .Respond(HttpStatusCode.OK, "")
            .Respond(HttpStatusCode.BadRequest, InvalidStatusBody)
            .Respond(HttpStatusCode.InternalServerError, "patch exploded");
        var client = MakeClient(handler);

        var ex = await Assert.ThrowsAsync<SessionUploadException>(
            () => client.UploadWithSelfHealAsync("session-1", WritePcm("mic.pcm", 100), WritePcm("system.pcm", 100)));

        Assert.Equal(500, ex.StatusCode);
        Assert.Equal(5, handler.Requests.Count);
    }

    [Fact]
    public async Task SelfHeal_OnUnrelatedFinalizeError_DoesNotPatch()
    {
        var handler = new StubHandler()
            .Respond(HttpStatusCode.OK, InitBody())
            .Respond(HttpStatusCode.OK, "")
            .Respond(HttpStatusCode.OK, "")
            .Respond(HttpStatusCode.InternalServerError, "boom");
        var client = MakeClient(handler);

        var ex = await Assert.ThrowsAsync<SessionUploadException>(
            () => client.UploadWithSelfHealAsync("session-1", WritePcm("mic.pcm", 100), WritePcm("system.pcm", 100)));

        Assert.Equal(500, ex.StatusCode);
        Assert.DoesNotContain(handler.Requests, r => r.Method == HttpMethod.Patch);
    }

    [Fact]
    public async Task SelfHeal_InvalidStatusAtInit_IsNotHealed()
    {
        // The heal belongs to finalize; an init rejection takes the caller's
        // backoff path like any other error.
        var handler = new StubHandler().Respond(HttpStatusCode.BadRequest, InvalidStatusBody);
        var client = MakeClient(handler);

        var ex = await Assert.ThrowsAsync<SessionUploadException>(
            () => client.UploadWithSelfHealAsync("session-1", WritePcm("mic.pcm", 100), WritePcm("system.pcm", 100)));

        Assert.True(ex.IsInvalidStatus);
        Assert.Single(handler.Requests);
    }

    // --- encrypted sidecars, streamed ---

    [Fact]
    public async Task Encrypted_ContentLengthIsHeaderPlusPlaintext_AndBodyDecryptsToTheOriginalPcm()
    {
        var pcm = Pattern(10_000);
        // Uneven chunks, including a short last one, as capture produces.
        var mic = WriteEncrypted("mic.enc.pcm", pcm, chunkSize: 3_333);
        var sys = WriteEncrypted("system.enc.pcm", pcm, chunkSize: 4_096);
        var expectedLength = 44 + ChunkLengths(mic).Sum(len => len - 28);
        Assert.Equal(44 + pcm.Length, expectedLength);

        var handler = new StubHandler()
            .Respond(HttpStatusCode.OK, InitBody())
            .Respond(HttpStatusCode.OK, "")
            .Respond(HttpStatusCode.OK, "")
            .Respond(HttpStatusCode.OK, OkBody);
        var client = MakeClient(handler);

        await client.UploadWithSelfHealAsync("session-1", mic, sys, decryptChunk: _encryptor.Decrypt);

        foreach (var (put, channels) in new[] { (handler.Requests[1], 1), (handler.Requests[2], 2) })
        {
            Assert.Equal(expectedLength.ToString(), put.Header("Content-Length"));
            Assert.Equal(expectedLength, put.Body.Length);
            Assert.Equal(WAVEncoder.BuildHeader(pcm.Length, 48000, channels), put.Body[..44]);
            Assert.Equal(pcm, put.Body[44..]);
        }
    }

    [Fact]
    public void Encrypted_TruncatedTrailingChunk_IsLeftOutOfLengthAndBody()
    {
        var pcm = Pattern(1_000);
        var path = WriteEncrypted("mic.enc.pcm", pcm, chunkSize: 400);
        // A writer stopped mid-chunk: a prefix promising more bytes than follow.
        using (var file = new FileStream(path, FileMode.Append))
        {
            file.Write(BitConverter.GetBytes(500u));
            file.Write(new byte[100]);
        }

        using var content = new EncryptedPcmWavContent(path, 48000, 1, _encryptor.Decrypt);

        Assert.Equal(pcm.Length, content.PlaintextLength);
        Assert.Equal(44 + pcm.Length, content.Headers.ContentLength);
    }

    [Fact]
    public async Task Encrypted_TamperedChunk_FailsInsteadOfSendingGarbage()
    {
        var path = WriteEncrypted("mic.enc.pcm", Pattern(1_000), chunkSize: 400);
        var bytes = File.ReadAllBytes(path);
        bytes[^5] ^= 0xFF; // flip a bit in the last chunk's tag
        File.WriteAllBytes(path, bytes);

        using var content = new EncryptedPcmWavContent(path, 48000, 1, _encryptor.Decrypt);

        await Assert.ThrowsAnyAsync<System.Security.Cryptography.CryptographicException>(
            () => content.CopyToAsync(Stream.Null));
    }

    // --- self-describing audio passes through ---

    [Theory]
    [InlineData(new byte[] { 0xFF, 0xF1 }, true)]  // MPEG-4 ADTS, no CRC
    [InlineData(new byte[] { 0xFF, 0xF0 }, true)]  // MPEG-4 ADTS, CRC present
    [InlineData(new byte[] { 0xFF, 0xF9 }, true)]  // MPEG-2 ADTS
    [InlineData(new byte[] { 0xFF, 0xF3 }, false)] // layer bits set: MPEG audio, not ADTS
    [InlineData(new byte[] { 0xFF, 0xFB }, false)] // MP3 frame sync
    [InlineData(new byte[] { 0xFF, 0xE1 }, false)] // syncword incomplete
    [InlineData(new byte[] { 0x00, 0xF1 }, false)]
    [InlineData(new byte[] { 0xFF }, false)]
    public void AudioFormat_RecognisesAdtsSyncOnly(byte[] prefix, bool expected)
    {
        Assert.Equal(expected, AudioFormat.IsAdtsSync(prefix));
        Assert.Equal(expected, AudioFormat.IsSelfDescribing(prefix));
    }

    [Fact]
    public void AudioFormat_RecognisesRiff() =>
        Assert.True(AudioFormat.IsSelfDescribing(WAVEncoder.Wrap(new byte[10], 48000, 1)));

    [Theory]
    [InlineData("riff")]
    [InlineData("adts")]
    public async Task SelfDescribingAudio_IsSentUnchanged_PlainAndEncrypted(string kind)
    {
        var audio = kind == "riff"
            ? WAVEncoder.Wrap(Pattern(600), 48000, 1)
            : [0xFF, 0xF1, 0x50, 0x80, .. Pattern(596)];
        var plain = Path.Combine(_tempDir, kind == "riff" ? "mic.wav" : "mic.aac");
        File.WriteAllBytes(plain, audio);
        var encrypted = WriteEncrypted("system.enc.pcm", audio, chunkSize: 3); // prefix spans chunks

        var handler = new StubHandler()
            .Respond(HttpStatusCode.OK, InitBody())
            .Respond(HttpStatusCode.OK, "")
            .Respond(HttpStatusCode.OK, "")
            .Respond(HttpStatusCode.OK, OkBody);
        var client = MakeClient(handler);

        await client.UploadWithSelfHealAsync("session-1", plain, encrypted, decryptChunk: _encryptor.Decrypt);

        // No 44-byte header stapled on: Content-Length is the audio alone.
        Assert.Equal(audio, handler.Requests[1].Body);
        Assert.Equal(audio, handler.Requests[2].Body);
        Assert.Equal(audio.Length.ToString(), handler.Requests[2].Header("Content-Length"));
        // Content-Type still comes from the signed recipe, never from the format.
        Assert.Equal("audio/wav", handler.Requests[2].Header("Content-Type"));
    }

    // --- fixtures ---

    private readonly AesGcmEncryptor _encryptor = new(Enumerable.Range(1, 32).Select(i => (byte)i).ToArray());

    private static void BindDevice(HttpRequestMessage request)
    {
        request.Headers.Add("DPoP", "proof-jws");
        request.Headers.Add("X-Install-ID", "install-123");
    }

    private static byte[] Pattern(int length)
    {
        var bytes = new byte[length];
        for (int i = 0; i < length; i++) bytes[i] = (byte)(i * 7 % 253);
        return bytes;
    }

    /// <summary>Writes <paramref name="plaintext"/> in the capture sidecar's encrypted chunk format.</summary>
    private string WriteEncrypted(string name, byte[] plaintext, int chunkSize)
    {
        var path = Path.Combine(_tempDir, name);
        using var file = File.Create(path);
        WriteEncryptedChunks(file, _encryptor, plaintext, chunkSize);
        return path;
    }

    internal static void WriteEncryptedChunks(Stream file, AesGcmEncryptor encryptor, byte[] plaintext, int chunkSize)
    {
        for (int offset = 0; offset < plaintext.Length; offset += chunkSize)
        {
            var encrypted = encryptor.Encrypt(plaintext[offset..Math.Min(offset + chunkSize, plaintext.Length)]);
            file.Write(BitConverter.GetBytes((uint)encrypted.Length));
            file.Write(encrypted);
        }
    }

    private static List<int> ChunkLengths(string path)
    {
        var bytes = File.ReadAllBytes(path);
        var lengths = new List<int>();
        for (int offset = 0; offset + 4 <= bytes.Length;)
        {
            var length = (int)BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(offset, 4));
            lengths.Add(length);
            offset += 4 + length;
        }
        return lengths;
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
        Dictionary<string, string> Headers,
        Dictionary<string, string> ContentHeaders)
    {
        public string BodyText => Encoding.Latin1.GetString(Body);

        /// <summary>Request and content headers together: everything that goes on the wire.</summary>
        public Dictionary<string, string> AllHeaders =>
            Headers.Concat(ContentHeaders).ToDictionary(h => h.Key, h => h.Value, StringComparer.OrdinalIgnoreCase);

        public string? Header(string name) => AllHeaders.GetValueOrDefault(name);
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
            // Reading the content here is what drives the streaming contents'
            // serialize path, so the recorded bytes are exactly what would go on the wire.
            var body = request.Content is null
                ? []
                : await request.Content.ReadAsByteArrayAsync(cancellationToken);

            Requests.Add(new RecordedRequest(
                request.Method,
                request.RequestUri!.ToString(),
                body,
                request.Headers.Authorization?.ToString(),
                request.Headers.ToDictionary(h => h.Key, h => string.Join(",", h.Value)),
                request.Content?.Headers.ToDictionary(h => h.Key, h => string.Join(",", h.Value)) ?? []));

            Assert.True(_responses.Count > 0, $"unexpected request: {request.Method} {request.RequestUri}");
            var (status, responseBody) = _responses.Dequeue();
            return new HttpResponseMessage(status) { Content = new StringContent(responseBody) };
        }
    }
}
