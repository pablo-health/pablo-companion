using PabloCompanion.Core;

namespace RecordHarness;

/// <summary>
/// Takes a finished recording from the queue to its note, the way the app does,
/// and gates every step: queued before upload, uploaded through signed URLs
/// (observed on the wire), audio kept while the note is drafted, then the note,
/// then the audio deleted and the queue empty.
///
/// Shared by the <c>record</c> and <c>visit</c> scenarios.
/// </summary>
internal sealed class QueuedUpload(string baseUrl, DeviceBoundClient client, string token)
{
    /// <param name="sessionId">Session the recording belongs to.</param>
    /// <param name="recording">The capture to upload.</param>
    /// <param name="pollForNote">Poll to the SOAP and reconcile the queue. Without it the
    /// gate stops once the upload is accepted and the audio is confirmed kept, which is
    /// where the app would be too until the note exists.</param>
    /// <param name="pollSeconds">SOAP poll deadline.</param>
    internal async Task<IReadOnlyList<Check>> RunAsync(
        string sessionId,
        FixtureRecorder.Outcome recording,
        bool pollForNote,
        double pollSeconds,
        CancellationToken cancellationToken)
    {
        var checks = new List<Check>();
        var queue = new UploadQueue(Path.Combine(
            Path.GetDirectoryName(recording.Directory.TrimEnd(Path.DirectorySeparatorChar)) ?? Path.GetTempPath(),
            $"queue-{Guid.NewGuid():N}"));

        queue.Add(sessionId, recording.MicPath, recording.SystemPath, recording.MixedPath);
        checks.Add(new Check(
            "queued before upload (durability anchor)",
            queue.Get(sessionId)?.State == UploadQueue.State.PendingUpload,
            $"{queue.Count} entry"));

        // Two clients on one recorder each, so the gate can see what went to the
        // backend and what went straight to storage.
        var backendWire = new WireRecorder();
        var storageWire = new WireRecorder();
        using var backendHttp = new HttpClient(backendWire);
        using var storageHttp = new HttpClient(storageWire) { Timeout = Timeout.InfiniteTimeSpan };

        var uploadClient = new AudioUploadClient(
            baseUrl: () => baseUrl,
            token: () => Task.FromResult(token),
            attachBinding: client.AttachBinding,
            clientHeaders: new Dictionary<string, string>
            {
                ["X-Client-Type"] = "pablo-companion-windows/1.0",
            },
            http: backendHttp,
            log: Harness.Log,
            storageHttp: storageHttp);

        string? status = null;
        var started = DateTimeOffset.UtcNow;
        int uploaded;
        try
        {
            uploaded = await queue.DrainAsync(async entry =>
            {
                var response = await uploadClient.UploadWithSelfHealAsync(
                    entry.SessionId, entry.MicPath, entry.SystemPath,
                    sampleRate: AudioUploadClient.DefaultSampleRate,
                    cancellationToken: cancellationToken);
                status = response.Status;
            });
        }
        catch (SessionUploadException ex) when (ex.StatusCode == 501)
        {
            Harness.Log($"upload 501: transcription is off on {baseUrl}");
            checks.Add(Harness.TranscriptionOffCheck());
            return checks;
        }
        var elapsed = DateTimeOffset.UtcNow - started;

        checks.Add(new Check(
            "upload accepted + transcribing",
            uploaded == 1 && status == "transcribing",
            $"status {status ?? "none"}, {elapsed.TotalSeconds:F0}s, "
                + $"{MiB(recording.MicPath) + MiB(recording.SystemPath):F1} MiB"));
        checks.Add(WireRecorder.SignedUrlCheck(
            backendWire.Exchanges, storageWire.Exchanges, new Uri(baseUrl).Host));

        var entry = queue.Get(sessionId);
        var audio = entry?.AudioPaths.ToList() ?? [];
        var kept = audio.Count > 0 && audio.All(File.Exists);
        checks.Add(new Check(
            "audio kept until the note exists",
            entry?.State == UploadQueue.State.AwaitingNote && kept,
            $"state {entry?.State.ToString() ?? "none"}, {(kept ? "files on disk" : "files missing")}"));

        if (!pollForNote)
        {
            Harness.Log("RECORD_EXPECT_SOAP != 1: gating at 'transcribing'; the audio stays until a note exists");
            return checks;
        }

        checks.Add(await SoapGate.PollAsync(client, token, sessionId, pollSeconds, cancellationToken));

        var confirmed = await queue.ReconcileAsync(async id =>
        {
            var session = await client.RequestAsync(
                HttpMethod.Get, $"/api/sessions/{id}", token, cancellationToken: cancellationToken);
            return session.Json.GetStringOrNull("status") switch
            {
                "pending_review" or "finalized" => UploadQueue.Outcome.NoteReady,
                "failed" => UploadQueue.Outcome.Failed,
                _ => UploadQueue.Outcome.StillWorking,
            };
        });
        var left = FixtureRecorder.AudioFiles(recording.Directory);
        var queued = queue.Count;
        if (queued == 0) queue.DeleteStore();
        checks.Add(new Check(
            "queue drained after the note",
            confirmed == 1 && queued == 0,
            $"confirmed {confirmed}, {queued} entries left"));
        checks.Add(new Check(
            "local audio deleted after the note",
            left.Count == 0,
            left.Count == 0 ? "capture directory has no audio" : $"left: {string.Join(", ", left)}"));
        return checks;
    }

    private static double MiB(string? path) =>
        path is not null && File.Exists(path) ? new FileInfo(path).Length / 1048576.0 : 0;
}
