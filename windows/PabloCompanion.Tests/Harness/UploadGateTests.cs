using System.Net;
using RecordHarness;

namespace PabloCompanion.Tests.Harness;

/// <summary>
/// The harness's upload gates: the queue lifecycle it runs a recording through,
/// the wire observation that proves the signed-URL path was taken, and the
/// capture floor. Each one decides whether a CI run reports green, so each is
/// pinned here rather than discovered on a runner.
/// </summary>
public class UploadGateTests : IDisposable
{
    private readonly string _tempDir;

    public UploadGateTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"harness_gate_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_tempDir);
    }

    public void Dispose()
    {
        GC.SuppressFinalize(this);
        if (Directory.Exists(_tempDir))
            Directory.Delete(_tempDir, recursive: true);
    }

    private string Touch(string name)
    {
        var path = Path.Combine(_tempDir, name);
        File.WriteAllBytes(path, [1, 2, 3, 4]);
        return path;
    }

    // --- Queue ---

    [Fact]
    public async Task Queue_KeepsAudioAfterUploadAndDeletesItOnceTheNoteExists()
    {
        var mic = Touch("s_mic.pcm");
        var system = Touch("s_system.pcm");
        var queue = new UploadQueue(Path.Combine(_tempDir, "queue"));
        queue.Add("s1", mic, system, mixedPath: null);

        Assert.Equal(1, await queue.DrainAsync(_ => Task.CompletedTask));
        Assert.Equal(UploadQueue.State.AwaitingNote, queue.Get("s1")?.State);
        Assert.True(File.Exists(mic) && File.Exists(system), "audio must survive the upload's acknowledgement");

        Assert.Equal(0, await queue.ReconcileAsync(_ => Task.FromResult(UploadQueue.Outcome.StillWorking)));
        Assert.True(File.Exists(mic), "audio must survive while the note is still drafting");

        Assert.Equal(1, await queue.ReconcileAsync(_ => Task.FromResult(UploadQueue.Outcome.NoteReady)));
        Assert.Equal(0, queue.Count);
        Assert.False(File.Exists(mic) || File.Exists(system));
    }

    [Fact]
    public async Task Queue_FailedUploadStaysQueuedWithItsAudio()
    {
        var mic = Touch("f_mic.pcm");
        var queue = new UploadQueue(Path.Combine(_tempDir, "queue"));
        queue.Add("s1", mic, null, null);

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => queue.DrainAsync(_ => throw new InvalidOperationException("413")));

        Assert.Equal(UploadQueue.State.PendingUpload, queue.Get("s1")?.State);
        Assert.True(File.Exists(mic));
    }

    [Fact]
    public async Task Queue_PersistsAcrossInstances()
    {
        var dir = Path.Combine(_tempDir, "queue");
        new UploadQueue(dir).Add("s1", Touch("p_mic.pcm"), null, null);

        var reopened = new UploadQueue(dir);
        Assert.Equal(UploadQueue.State.PendingUpload, reopened.Get("s1")?.State);
        Assert.Equal(1, await reopened.DrainAsync(_ => Task.CompletedTask));
        Assert.Equal(UploadQueue.State.AwaitingNote, new UploadQueue(dir).Get("s1")?.State);
    }

    // --- Signed-URL wire gate ---

    private static WireRecorder.Exchange Post(string path, int status = 200) =>
        new("POST", "api.example", path, status);

    private static WireRecorder.Exchange Put(string host = "storage.example", int status = 200) =>
        new("PUT", host, "/bucket/object", status);

    [Fact]
    public void SignedUrl_PassesOnInitTwoStoragePutsAndFinalize()
    {
        var check = WireRecorder.SignedUrlCheck(
            [Post("/api/sessions/s/upload-audio/init"), Post("/api/sessions/s/upload-audio/finalize")],
            [Put(), Put()],
            "api.example");

        Assert.True(check.Ok, check.Detail);
    }

    [Fact]
    public void SignedUrl_FailsWhenTheMultipartPostWasSent()
    {
        var check = WireRecorder.SignedUrlCheck(
            [Post("/api/sessions/s/upload-audio")],
            [],
            "api.example");

        Assert.False(check.Ok);
        Assert.Contains("SENT", check.Detail);
    }

    [Fact]
    public void SignedUrl_FailsWhenAudioWentThroughTheBackend()
    {
        var check = WireRecorder.SignedUrlCheck(
            [Post("/api/sessions/s/upload-audio/init"), Post("/api/sessions/s/upload-audio/finalize")],
            [Put("api.example"), Put("api.example")],
            "api.example");

        Assert.False(check.Ok);
    }

    [Fact]
    public void SignedUrl_FailsWhenFinalizeWasRefused()
    {
        var check = WireRecorder.SignedUrlCheck(
            [Post("/api/sessions/s/upload-audio/init"), Post("/api/sessions/s/upload-audio/finalize", 400)],
            [Put(), Put()],
            "api.example");

        Assert.False(check.Ok);
    }

    [Fact]
    public async Task WireRecorder_KeepsNoQueryString()
    {
        var recorder = new WireRecorder(new StubHandler(HttpStatusCode.OK));
        using var http = new HttpClient(recorder);

        await http.PutAsync("https://storage.example/b/o?X-Goog-Signature=secret", new ByteArrayContent([]));

        var exchange = Assert.Single(recorder.Exchanges);
        Assert.Equal("/b/o", exchange.Path);
        Assert.Equal(200, exchange.Status);
        Assert.DoesNotContain("secret", exchange.ToString());
    }

    private sealed class StubHandler(HttpStatusCode status) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(new HttpResponseMessage(status));
    }

    // --- Capture floor ---

    private static FixtureRecorder.Outcome Capture(long mixCycles, long trimmed = 0, long mixErrors = 0) =>
        new(true, "", "mic.pcm", "system.pcm", MicRms: 100, SystemRms: 100, MixErrors: mixErrors)
        {
            MixCycles = mixCycles,
            BytesWritten = 1000,
            SystemTrimmedFrames = trimmed,
        };

    [Fact]
    public void CaptureChecks_FailAGraphThatStalledEarly()
    {
        var stalled = Capture(mixCycles: 1).Checks(seconds: 380);

        Assert.False(stalled.Single(c => c.Name == "capture completed").Ok);
        Assert.True(Capture(mixCycles: 378).Checks(380).Single(c => c.Name == "capture completed").Ok);
    }

    [Fact]
    public void CaptureChecks_FailOnDroppedSamples()
    {
        Assert.False(Capture(4000, trimmed: 10).Checks(380).Single(c => c.Name == "no dropped samples").Ok);
        Assert.False(Capture(4000, mixErrors: 1).Checks(380).Single(c => c.Name == "no dropped samples").Ok);
        Assert.True(Capture(4000).Checks(380).Single(c => c.Name == "no dropped samples").Ok);
    }
}
