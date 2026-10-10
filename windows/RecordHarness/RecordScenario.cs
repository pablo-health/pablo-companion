namespace RecordHarness;

/// <summary>
/// <c>PRACTICE_SCENARIO=record</c>: drives the REAL companion recording path
/// against a deployed backend, end to end:
///
///   sign in (pinned test user) → device enroll (DPoP) → seed patient + schedule
///   session → <b>record through the real AudioCapture graph</b> (mic + system
///   fixtures injected, separated / 48 kHz / raw-PCM sidecars — the exact
///   RecordingService config; see <see cref="FixtureRecorder"/>) → <b>queue, then
///   upload through signed URLs via the real client</b> (init, one PUT per channel
///   straight to storage, finalize; observed on the wire) → poll the session to
///   <c>transcribing</c>, or to <c>pending_review</c> + a 4-section SOAP, then
///   delete the local audio and drain the queue (see <see cref="QueuedUpload"/>).
///
/// The session is left in <c>in_progress</c> (not <c>recording_complete</c>) before
/// the upload, so finalize first returns <c>400 INVALID_STATUS</c> and the shared
/// self-heal recovers it — exercising that path on the live backend.
///
/// Length matters: a session longer than a few minutes is larger than the load
/// balancer accepts in one request, which is what the signed-URL path exists for.
/// Run it with a fixture and <c>RECORD_SECONDS</c> past five minutes to prove it.
///
/// The Windows mirror of the macOS <c>RecordScenario</c>; the two gate on the same
/// checks and should change together.
///
/// Environment:
///   PRACTICE_BASE_URL       backend base URL
///   FB_API_KEY + FB_* creds sign-in plumbing (FB_REFRESH_TOKEN first, then TOTP)
///   RECORD_MIC_AUDIO        path to the therapist (mic) WAV fixture (required)
///   RECORD_SYSTEM_AUDIO     path to the client (system) WAV fixture (required)
///   RECORD_SECONDS          capture duration (default 20)
///   RECORD_EXPECT_SOAP      "1" to poll for the full SOAP; otherwise gate at
///                           "transcribing". Dev and prod both run real ASR.
///   RECORD_POLL_SECONDS     SOAP poll deadline when expecting SOAP (default 300)
///   RECORD_ALLOW_TRANSCRIPTION_OFF  "1" lets a 501 upload (transcription off) pass
///   REFRESH_OUT             path to write the rotated refresh token to
/// </summary>
public static class RecordScenario
{
    public static async Task RunAsync(CancellationToken cancellationToken = default)
    {
        var baseUrl = Harness.Env("PRACTICE_BASE_URL") ?? "https://app.pablo.health";
        var (micFixture, systemFixture) = Harness.RequireFixtures();
        var auth = await Harness.SignInAsync(cancellationToken);

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

            // -- 1. Enrollment --------------------------------------------------
            var enrollment = await client.EnrollAsync(idToken, refreshToken, cancellationToken: cancellationToken);
            var token = enrollment.IdToken;
            checks.Add(new Check(
                "enrollment accepted at /native/exchange",
                enrollment.ExchangeStatus == 200,
                $"status {enrollment.ExchangeStatus}, key_storage={enrollment.KeyStorage}"));

            // -- 2. Seed patient + schedule session (as the companion) -----------
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

            // -- 3. Record through the real capture graph from file fixtures -----
            var recording = await FixtureRecorder.RecordAsync(
                micFixture, systemFixture, recordSeconds,
                cancellationToken: cancellationToken,
                touch: () => client.RequestAsync(HttpMethod.Post, "/api/auth/session/touch", token,
                    cancellationToken: cancellationToken));
            checks.AddRange(recording.Checks(recordSeconds));

            // -- 4. Queue, upload through signed URLs, poll to the note ----------
            checks.AddRange(await new QueuedUpload(baseUrl, client, token).RunAsync(
                sessionId, recording, expectSoap, pollSeconds, cancellationToken));

            GateSummary.Report(checks, "record gate summary", "RECORD GATE PASSED");
        }
    }
}
