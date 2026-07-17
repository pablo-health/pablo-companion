using System.Text.Json;
using PabloCompanion.Core;

namespace RecordHarness;

/// <summary>
/// Drives the REAL companion recording path against a deployed backend, end to end:
///
///   sign in (pinned test user) → device enroll (DPoP) → seed patient + schedule
///   session → <b>record through the real AudioCapture graph</b> (mic + system
///   fixtures injected, separated / 48 kHz / raw-PCM sidecars — the exact
///   RecordingService config; see <see cref="FixtureRecorder"/>) → <b>upload via
///   the real client wire path</b> (<see cref="AudioUploadClient"/>) → poll the
///   session to <c>transcribing</c> (dev) or <c>pending_review</c> + a 4-section
///   SOAP (prod, real ASR).
///
/// The session is left in <c>in_progress</c> (not <c>recording_complete</c>) before
/// the upload, so the first attempt returns <c>400 INVALID_STATUS</c> and the
/// shared self-heal recovers it — exercising that path on the live backend.
///
/// The Windows mirror of the macOS <c>RecordScenario</c>; the two gate on the same
/// checks and should change together.
///
/// Environment:
///   PRACTICE_BASE_URL       backend base URL
///   FB_API_KEY + FB_* creds sign-in plumbing
///   RECORD_MIC_AUDIO        path to the therapist (mic) WAV fixture (required)
///   RECORD_SYSTEM_AUDIO     path to the client (system) WAV fixture (required)
///   RECORD_SECONDS          capture duration (default 20)
///   RECORD_EXPECT_SOAP      "1" to poll for the full SOAP (prod/assemblyai);
///                           otherwise gate at "transcribing" (dev runs whisper→mock)
///   RECORD_POLL_SECONDS     SOAP poll deadline when expecting SOAP (default 300)
///   REFRESH_OUT             path to write the rotated refresh token to
/// </summary>
public static class RecordScenario
{
    private sealed record Check(string Name, bool Ok, string Detail);

    public static async Task RunAsync(CancellationToken cancellationToken = default)
    {
        var baseUrl = Harness.Env("PRACTICE_BASE_URL") ?? "https://app.pablo.health";

        var micFixture = Harness.RequireEnv("RECORD_MIC_AUDIO");
        var systemFixture = Harness.RequireEnv("RECORD_SYSTEM_AUDIO");
        foreach (var fixture in new[] { micFixture, systemFixture })
        {
            if (!File.Exists(fixture))
                throw new HarnessException($"Audio fixture not found: {fixture}");
        }

        var apiKey = Harness.RequireEnv("FB_API_KEY");

        var auth = await new FirebaseAuth(apiKey).MintAsync(
            Harness.Env("FB_REFRESH_TOKEN"),
            Harness.Env("FB_EMAIL"),
            Harness.Env("FB_PASSWORD"),
            Harness.Env("FB_TOTP_SECRET"),
            cancellationToken);
        Harness.Log($"Signed in via {auth.Mode}");

        // Persist the rotated refresh token so the next run can take the cheap
        // path — the TOTP finalize quota is the reason this exists.
        var refreshOut = Harness.Env("REFRESH_OUT");
        if (refreshOut is not null)
        {
            try { await File.WriteAllTextAsync(refreshOut, auth.RefreshToken, cancellationToken); }
            catch (IOException ex) { Harness.Log($"could not write REFRESH_OUT: {ex.Message}"); }
        }

        await new Driver(
            baseUrl,
            auth.IdToken,
            auth.RefreshToken,
            micFixture,
            systemFixture,
            Harness.EnvDouble("RECORD_SECONDS", 20),
            Harness.Env("RECORD_EXPECT_SOAP") == "1",
            Harness.EnvDouble("RECORD_POLL_SECONDS", 300)
        ).RunAsync(cancellationToken);
    }

    private sealed class Driver(
        string baseUrl,
        string idToken,
        string refreshToken,
        string micFixture,
        string systemFixture,
        double recordSeconds,
        bool expectSoap,
        double pollSeconds)
    {
        public async Task RunAsync(CancellationToken cancellationToken)
        {
            var checks = new List<Check>();
            var installId = Guid.NewGuid().ToString().ToLowerInvariant();
            using var client = new DeviceBoundClient(baseUrl, installId);
            Harness.Log($"install_id for this run: {installId}");

            // ── 1. Enrollment ────────────────────────────────────────────────
            var enrollment = await client.EnrollAsync(idToken, refreshToken, cancellationToken: cancellationToken);
            var token = enrollment.IdToken;
            checks.Add(new Check(
                "enrollment accepted at /native/exchange",
                enrollment.ExchangeStatus == 200,
                $"status {enrollment.ExchangeStatus}, key_storage={enrollment.KeyStorage}"));

            // ── 2. Seed patient + schedule session (as the companion) ─────────
            var noise = Guid.NewGuid().ToString()[..8].ToLowerInvariant();
            var patient = await client.RequestAsync(HttpMethod.Post, "/api/patients", token, new
            {
                first_name = "E2E",
                last_name = $"Record-{noise}",
                status = "active",
            }, cancellationToken);
            var patientId = patient.Json.GetStringOrNull("id");
            if (patient.Status is not (200 or 201) || string.IsNullOrEmpty(patientId))
                throw new HarnessException($"patient create failed: {patient.Status} {patient.BodyPrefix}");

            var scheduled = await client.RequestAsync(HttpMethod.Post, "/api/sessions/schedule", token, new
            {
                patient_id = patientId,
                scheduled_at = DeviceBoundClient.Iso8601(DateTimeOffset.UtcNow),
                source = "companion",
            }, cancellationToken);
            var sessionId = scheduled.Json.GetStringOrNull("id");
            if (scheduled.Status is not (200 or 201) || string.IsNullOrEmpty(sessionId))
                throw new HarnessException($"schedule failed: {scheduled.Status} {scheduled.BodyPrefix}");
            checks.Add(new Check("session scheduled", true, $"id {sessionId}"));

            // Move to in_progress only — the upload self-heal must drive the
            // recording_complete transition (that's the path under test).
            var inProgress = await client.RequestAsync(
                HttpMethod.Patch, $"/api/sessions/{sessionId}/status", token,
                new { status = "in_progress" }, cancellationToken);
            checks.Add(new Check("session in_progress", inProgress.Status == 200, $"status {inProgress.Status}"));

            // ── 3. Record through the real capture graph from file fixtures ───
            var recording = await FixtureRecorder.RecordAsync(
                micFixture, systemFixture, recordSeconds, cancellationToken: cancellationToken);
            checks.Add(new Check("capture completed", recording.Ok, recording.Detail));
            checks.Add(new Check(
                "per-channel audio liveness",
                recording.MicRms > 1 && recording.SystemRms > 1,
                $"mic RMS {recording.MicRms:F0}, system RMS {recording.SystemRms:F0}"));
            checks.Add(new Check(
                "no mix errors",
                recording.MixErrors == 0,
                $"mix errors {recording.MixErrors}"));

            // ── 4. Upload via the real client wire path (with self-heal) ──────
            var uploadClient = new AudioUploadClient(
                baseUrl: () => baseUrl,
                token: () => Task.FromResult(token),
                attachBinding: client.AttachBinding,
                clientHeaders: new Dictionary<string, string>
                {
                    ["X-Client-Type"] = "pablo-companion-windows/1.0",
                },
                log: Harness.Log);

            try
            {
                var uploaded = await uploadClient.UploadWithSelfHealAsync(
                    sessionId, recording.MicPath, recording.SystemPath,
                    cancellationToken: cancellationToken);
                checks.Add(new Check(
                    "upload accepted + transcribing",
                    uploaded.Status == "transcribing",
                    $"status {uploaded.Status}"));
            }
            catch (SessionUploadException ex) when (ex.StatusCode == 501)
            {
                // Server-side transcription disabled on this env — the record path is
                // proven up to the upload; there is nothing further to gate.
                Harness.Log($"upload-audio 501: transcription disabled on {baseUrl}");
                checks.Add(new Check("upload path reached (transcription disabled, 501)", true, "status 501"));
                Summarize(checks);
                return;
            }

            // ── 5. Poll for the SOAP (prod/assemblyai only) ───────────────────
            if (expectSoap)
            {
                checks.Add(await PollForSoapAsync(client, token, sessionId, cancellationToken));
            }
            else
            {
                Harness.Log("RECORD_EXPECT_SOAP != 1 — gating at 'transcribing' (dev runs whisper→mock)");
            }

            Summarize(checks);
        }

        // --- SOAP poll ---

        private async Task<Check> PollForSoapAsync(
            DeviceBoundClient client, string token, string sessionId, CancellationToken cancellationToken)
        {
            var deadline = DateTimeOffset.UtcNow.AddSeconds(pollSeconds);
            var lastStatus = "transcribing";

            while (DateTimeOffset.UtcNow < deadline)
            {
                var poll = await client.RequestAsync(
                    HttpMethod.Get, $"/api/sessions/{sessionId}", token, cancellationToken: cancellationToken);
                if (poll.Status != 200)
                    throw new HarnessException($"poll failed: {poll.Status} {poll.BodyPrefix}");

                lastStatus = poll.Json.GetStringOrNull("status") ?? lastStatus;
                if (lastStatus == "failed")
                    return new Check("SOAP generated", false, "session status 'failed'");

                if (lastStatus == "pending_review")
                {
                    var note = poll.Json.GetPropertyOrNull("note");
                    DumpNote(note);
                    return EvaluateSoap(note);
                }

                await Task.Delay(TimeSpan.FromSeconds(5), cancellationToken);
            }

            return new Check("SOAP generated", false, $"deadline hit (last status '{lastStatus}')");
        }

        /// <summary>
        /// Logs the generated SOAP note so a run can be eyeballed against the fixture
        /// audio. The session is always one the harness itself created in the pinned
        /// test tenant from synthetic speech — never a real patient's note.
        /// </summary>
        private static void DumpNote(JsonElement? note)
        {
            if (note is null || note.Value.ValueKind != JsonValueKind.Object)
            {
                Harness.Log("generated note: nil");
                return;
            }

            var noteType = note.GetStringOrNull("note_type") ?? "?";
            var content = note.GetPropertyOrNull("content");
            if (content is null) return;

            var text = JsonSerializer.Serialize(content, new JsonSerializerOptions { WriteIndented = true });
            Harness.Log($"""
                ───── generated SOAP (note_type={noteType}) ─────
                {text}
                ──────────────────────────────────────
                """);
        }

        /// <summary>
        /// The embedded note must be a 4-section SOAP with at least one section
        /// carrying transcript-anchored content — see <see cref="SoapGate"/>.
        /// </summary>
        private static Check EvaluateSoap(JsonElement? note)
        {
            if (note is null || note.Value.ValueKind != JsonValueKind.Object)
                return new Check("SOAP generated", false, "no note on session");

            var noteType = note.GetStringOrNull("note_type");
            if (noteType != "soap")
                return new Check("SOAP generated", false, $"note_type {noteType ?? "nil"}");

            var result = SoapGate.Evaluate(note.GetPropertyOrNull("content"));
            return new Check("4-section SOAP with content", result.Ok, result.Detail);
        }

        // --- Summary ---

        private static void Summarize(IReadOnlyList<Check> checks)
        {
            var pad = checks.Count == 0 ? 0 : checks.Max(c => c.Name.Length);
            var lines = string.Join("\n", checks.Select(c =>
                $"  [{(c.Ok ? "PASS" : "FAIL")}] {c.Name.PadRight(pad)}  {c.Detail}"));

            Harness.Log($"""
                ───── record gate summary ─────
                {lines}
                ───────────────────────────────
                """);

            var failed = checks.Where(c => !c.Ok).Select(c => c.Name).ToList();
            if (failed.Count > 0)
                throw new HarnessException($"Gate FAILED: {string.Join(", ", failed)}");

            Harness.Log("RECORD GATE PASSED ✓");
        }
    }
}
