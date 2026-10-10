using System.Net;
using System.Security.Cryptography;
using AudioCapture.Storage;
using PabloCompanion.Core;

namespace PabloCompanion.Tests.Core;

/// <summary>
/// Runs alone: this test points the process temp directory at an empty folder to
/// prove the upload writes nothing there, and any test running alongside it
/// would write its own fixtures into that folder.
/// </summary>
[CollectionDefinition(nameof(TempDirectoryIsolation), DisableParallelization = true)]
public sealed class TempDirectoryIsolation;

/// <summary>
/// A full-length encrypted session goes to storage without a plaintext copy on
/// disk and without the sidecar landing on the heap.
///
/// The old path decrypted each sidecar to <c>%TEMP%</c> after reading the whole
/// encrypted file into memory: for a 50-minute session, hundreds of megabytes on
/// the heap of an app that is also recording, and session audio left in plaintext
/// wherever a crash interrupted the cleanup.
/// </summary>
[Collection(nameof(TempDirectoryIsolation))]
public sealed class LargeEncryptedUploadTests : IDisposable
{
    private const int FixtureBytes = 200 * 1024 * 1024;
    private const int ChunkBytes = 64 * 1024;
    private const long HeapBudgetBytes = 64L * 1024 * 1024;

    private readonly string _fixtureDir;
    private readonly AesGcmEncryptor _encryptor = new(RandomNumberGenerator.GetBytes(32));

    public LargeEncryptedUploadTests()
    {
        // Deliberately not under the temp directory: the assertion is that nothing
        // appears there.
        _fixtureDir = Path.Combine(AppContext.BaseDirectory, $"upload_fixture_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_fixtureDir);
    }

    public void Dispose()
    {
        _encryptor.Dispose();
        if (Directory.Exists(_fixtureDir))
            Directory.Delete(_fixtureDir, recursive: true);
    }

    [Fact]
    public async Task TwoHundredMegabyteSidecar_StreamsWithNoTempFilesAndFlatHeap()
    {
        var (micPath, expectedHash) = WriteFixture("mic.enc.pcm", FixtureBytes, channels: 1);
        var (systemPath, _) = WriteFixture("system.enc.pcm", 4096, channels: 2);

        var sandboxTemp = Path.Combine(_fixtureDir, "temp");
        Directory.CreateDirectory(sandboxTemp);
        var originalTmp = Environment.GetEnvironmentVariable("TMP");
        var originalTemp = Environment.GetEnvironmentVariable("TEMP");

        var handler = new StreamingStubHandler();
        var client = new AudioUploadClient(
            baseUrl: () => "https://api.example.test",
            token: () => Task.FromResult("test-token"),
            http: new HttpClient(handler, disposeHandler: false),
            storageHttp: new HttpClient(handler, disposeHandler: false));

        GC.Collect();
        GC.WaitForPendingFinalizers();
        var baseline = GC.GetTotalMemory(forceFullCollection: true);

        try
        {
            Environment.SetEnvironmentVariable("TMP", sandboxTemp + Path.DirectorySeparatorChar);
            Environment.SetEnvironmentVariable("TEMP", sandboxTemp + Path.DirectorySeparatorChar);
            Assert.StartsWith(sandboxTemp, Path.GetTempPath());

            await client.UploadWithSelfHealAsync(
                "session-1", micPath, systemPath, decryptChunk: _encryptor.Decrypt);
        }
        finally
        {
            Environment.SetEnvironmentVariable("TMP", originalTmp);
            Environment.SetEnvironmentVariable("TEMP", originalTemp);
        }

        Assert.Empty(Directory.EnumerateFileSystemEntries(sandboxTemp, "*", SearchOption.AllDirectories));

        var therapistPut = handler.Puts[0];
        Assert.Equal(44L + FixtureBytes, therapistPut.Length);
        Assert.Equal(44L + FixtureBytes, therapistPut.DeclaredLength);
        Assert.Equal(expectedHash, therapistPut.Sha256);

        var peakAboveBaseline = handler.PeakLiveHeap - baseline;
        Assert.True(
            peakAboveBaseline < HeapBudgetBytes,
            $"live heap peaked {peakAboveBaseline / (1024 * 1024)} MiB above baseline while streaming");
    }

    /// <summary>
    /// Writes a sidecar in capture's encrypted chunk format, generating it a chunk
    /// at a time, and returns the SHA-256 of the WAV the upload should produce.
    /// </summary>
    private (string Path, byte[] Sha256) WriteFixture(string name, int plaintextBytes, int channels)
    {
        var path = Path.Combine(_fixtureDir, name);
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        hash.AppendData(WAVEncoder.BuildHeader(plaintextBytes, AudioUploadClient.DefaultSampleRate, channels));

        using var file = File.Create(path);
        var chunk = new byte[ChunkBytes];
        for (int written = 0; written < plaintextBytes; written += chunk.Length)
        {
            var size = Math.Min(ChunkBytes, plaintextBytes - written);
            if (size != chunk.Length) chunk = new byte[size];
            for (int i = 0; i < chunk.Length; i++) chunk[i] = (byte)((written + i) * 31 % 251);
            hash.AppendData(chunk);

            var encrypted = _encryptor.Encrypt(chunk);
            file.Write(BitConverter.GetBytes((uint)encrypted.Length));
            file.Write(encrypted);
        }
        return (path, hash.GetHashAndReset());
    }

    private sealed record PutRecord(long Length, long? DeclaredLength, byte[] Sha256);

    /// <summary>
    /// Answers init / PUT / finalize, consuming each PUT body as a stream (hashed,
    /// never buffered) and sampling the live heap as it goes.
    /// </summary>
    private sealed class StreamingStubHandler : HttpMessageHandler
    {
        private const string InitBody =
            """{"session_id":"session-1","therapist":{"upload":{"url":"https://storage.example.test/t","method":"PUT","headers":{"Content-Type":"audio/wav"},"fields":{}},"gcs_path":"t"},"client":{"upload":{"url":"https://storage.example.test/c","method":"PUT","headers":{"Content-Type":"audio/wav"},"fields":{}},"gcs_path":"c"},"max_bytes":2147483648}""";

        private const string OkBody =
            """{"id":"session-1","status":"transcribing","queue":"transcribe","message":"ok"}""";

        public List<PutRecord> Puts { get; } = [];

        public long PeakLiveHeap { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var url = request.RequestUri!.ToString();
            if (request.Method == HttpMethod.Put)
            {
                using var sink = new HashingSink(this);
                await request.Content!.CopyToAsync(sink, cancellationToken);
                Puts.Add(new PutRecord(sink.Length, request.Content.Headers.ContentLength, sink.Finish()));
                return new HttpResponseMessage(HttpStatusCode.OK);
            }

            var body = url.EndsWith("/init") ? InitBody : OkBody;
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(body) };
        }

        private void SampleHeap() =>
            PeakLiveHeap = Math.Max(PeakLiveHeap, GC.GetTotalMemory(forceFullCollection: true));

        private sealed class HashingSink(StreamingStubHandler owner) : Stream
        {
            private readonly IncrementalHash _hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            private int _writes;

            public override long Length => _length;
            private long _length;

            public byte[] Finish() => _hash.GetHashAndReset();

            public override void Write(byte[] buffer, int offset, int count) =>
                Write(buffer.AsSpan(offset, count));

            public override void Write(ReadOnlySpan<byte> buffer)
            {
                _hash.AppendData(buffer);
                _length += buffer.Length;
                // A forced collection measures what is actually live, not garbage
                // the GC simply hasn't got round to; sampled so the test stays fast.
                if (++_writes % 256 == 0) owner.SampleHeap();
            }

            public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
            {
                Write(buffer.Span);
                return ValueTask.CompletedTask;
            }

            public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
            {
                Write(buffer.AsSpan(offset, count));
                return Task.CompletedTask;
            }

            public override bool CanRead => false;
            public override bool CanSeek => false;
            public override bool CanWrite => true;
            public override long Position { get => _length; set => throw new NotSupportedException(); }
            public override void Flush() { }
            public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
            public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
            public override void SetLength(long value) => throw new NotSupportedException();

            protected override void Dispose(bool disposing)
            {
                if (disposing) _hash.Dispose();
                base.Dispose(disposing);
            }
        }
    }
}
