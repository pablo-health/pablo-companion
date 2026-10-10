using PabloCompanion.Core;

namespace RecordHarness;

/// <summary>
/// <c>PRACTICE_SCENARIO=visit</c>: the path a clinician takes for a telehealth
/// visit with a client nobody has asked about AI-assisted notes, as one flow:
///
///   sign in → device enroll (DPoP) → turn on asking clients → seed a client and
///   a telehealth appointment → the consent check reads "ask on the recording",
///   and the script names the practice's audio window → start the session from
///   the appointment saying so → record through the real capture graph → the
///   client answers on the recording →
///   - <c>VISIT_ANSWER=agree</c> (default): the answer is saved as given over
///     telehealth; stop, queue and upload through signed URLs; poll to a
///     four-section SOAP; the local audio is kept until the note exists, then
///     deleted.
///   - <c>VISIT_ANSWER=decline</c>: the app's decline path. Stop partway, discard
///     every file and the queue entry, return the session to a hand-written note,
///     save the decline. Nothing is uploaded, no audio is left, and a later
///     recorded start is refused with <c>CLIENT_DECLINED_AI_NOTES</c>.
///
/// Its own scenario rather than a <c>record</c> option: <c>record</c> starts from
/// <c>/api/sessions/schedule</c> and deliberately leaves the session
/// <c>in_progress</c> so the upload self-heal runs on the live backend. Starting
/// from an appointment through the consent gate would change what that gate proves.
///
/// The practice's ask-clients setting is put back as it was when the run ends,
/// pass or fail, and read back.
///
/// The Windows mirror of the macOS <c>VisitScenario</c>.
///
/// Environment: as <c>record</c> (PRACTICE_BASE_URL, FB_* sign-in, REFRESH_OUT,
/// RECORD_MIC_AUDIO, RECORD_SYSTEM_AUDIO, RECORD_SECONDS, RECORD_POLL_SECONDS,
/// RECORD_ALLOW_TRANSCRIPTION_OFF), plus VISIT_ANSWER.
/// </summary>
public static class VisitScenario
{
    public static async Task RunAsync(CancellationToken cancellationToken = default)
    {
        var baseUrl = Harness.Env("PRACTICE_BASE_URL") ?? "https://app.pablo.health";
        var answer = Harness.Env("VISIT_ANSWER") ?? "agree";
        if (answer is not ("agree" or "decline"))
            throw new HarnessException($"VISIT_ANSWER must be 'agree' or 'decline', not '{answer}'");
        var (mic, system) = Harness.RequireFixtures();
        var auth = await Harness.SignInAsync(cancellationToken);

        var installId = Guid.NewGuid().ToString().ToLowerInvariant();
        Harness.Log($"install_id for this run: {installId}");
        using var client = new DeviceBoundClient(baseUrl, installId);
        var enrollment = await client.EnrollAsync(auth.IdToken, auth.RefreshToken, cancellationToken: cancellationToken);
        var token = enrollment.IdToken;
        var checks = new List<Check>
        {
            new("enrollment accepted at /native/exchange", enrollment.ExchangeStatus == 200,
                $"status {enrollment.ExchangeStatus}, key_storage={enrollment.KeyStorage}"),
        };

        var practice = new PracticeSetting(client, token);
        var before = await practice.ReadAsync(cancellationToken);
        var driver = new Driver(baseUrl, client, token, mic, system,
            Harness.EnvDouble("RECORD_SECONDS", 20), Harness.EnvDouble("RECORD_POLL_SECONDS", 300));
        try
        {
            await driver.RunAsync(checks, declines: answer == "decline", cancellationToken);
        }
        finally
        {
            checks.Add(await practice.RestoreAsync(before, restoreRetention: false, cancellationToken));
        }
        GateSummary.Report(checks, $"visit ({answer}) gate summary", $"VISIT {answer.ToUpperInvariant()} GATE PASSED");
    }

    private sealed class Driver(
        string baseUrl,
        DeviceBoundClient client,
        string token,
        string micFixture,
        string systemFixture,
        double seconds,
        double pollSeconds)
    {
        private readonly Visits _visits = new(client, token, "Visit");

        public async Task RunAsync(List<Check> checks, bool declines, CancellationToken cancellationToken)
        {
            var turnOn = await client.RequestAsync(HttpMethod.Put, PracticeSetting.ConsentPath, token,
                new { ask_clients_about_ai_notes = true }, cancellationToken);
            var setting = await new PracticeSetting(client, token).ReadAsync(cancellationToken);
            checks.Add(new Check(
                "practice asks clients",
                turnOn.Status is >= 200 and < 300 && setting.Asked,
                $"PUT HTTP {turnOn.Status}, retention {setting.RetentionDays} days"));

            var consent = new RecordingConsentClient(
                () => baseUrl, () => Task.FromResult(token), client.AttachBinding,
                new Dictionary<string, string> { ["X-Client-Type"] = "pablo-companion-windows/1.0" });
            var visit = await _visits.SeedAsync(telehealth: true, patientId: null, cancellationToken);

            // -- The check before arming -----------------------------------------
            var read = await consent.CheckAsync(visit.AppointmentId, cancellationToken: cancellationToken);
            checks.Add(new Check(
                "telehealth, nothing on file: ask on the recording",
                read.Consent == new RecordingConsent.AskOnRecording(AiConsentModality.Telehealth),
                $"{read.Consent}"));
            var spoken = string.Join(" ", ConsentScript.Lines(read.AudioRetentionDays));
            var wording = setting.RetentionDays == ConsentScript.DeletedOnSigning
                ? "deleted once your note is signed"
                : $"kept for up to {ConsentScript.Retention(setting.RetentionDays)}";
            checks.Add(new Check(
                "script states the practice's audio window",
                read.AudioRetentionDays == setting.RetentionDays && spoken.Contains(wording, StringComparison.Ordinal),
                $"setting {setting.RetentionDays} days, expected \"{wording}\""));

            // -- "Ask now": start, saying so, then the app's in_progress ---------
            var started = await _visits.StartAsync(visit.AppointmentId, asking: true, cancellationToken);
            var sessionId = started.Json.GetStringOrNull("id");
            if (started.Status is not (>= 200 and < 300) || string.IsNullOrEmpty(sessionId))
                throw new HarnessException($"asking start refused: HTTP {started.Status} {started.BodyPrefix}");
            var running = await client.RequestAsync(HttpMethod.Patch, $"/api/sessions/{sessionId}/status", token,
                new { status = "in_progress" }, cancellationToken);
            checks.Add(new Check(
                "'Ask now' start accepted, session in_progress",
                running.Status == 200,
                $"session {sessionId}, in_progress HTTP {running.Status}"));

            if (declines)
                await DeclineAsync(checks, visit, sessionId, consent, cancellationToken);
            else
                await AgreeAsync(checks, visit, sessionId, consent, cancellationToken);
        }

        // -- Agree ----------------------------------------------------------------

        private async Task AgreeAsync(
            List<Check> checks, Visits.Visit visit, string sessionId, RecordingConsentClient consent,
            CancellationToken cancellationToken)
        {
            // The answer is given while recording, once the clinician has read the
            // script aloud.
            var answer = new AiConsentAnswer(
                AiConsentEntry.ConsentedDecision, AiConsentModality.Telehealth, AiConsentGiver.Client, "At home");
            var recording = await FixtureRecorder.RecordAsync(
                micFixture, systemFixture, seconds,
                cancellationToken: cancellationToken,
                midway: () => consent.RecordAsync(answer, visit.PatientId, cancellationToken),
                touch: Touch(cancellationToken));
            checks.AddRange(recording.Checks(seconds));

            var current = await _visits.CurrentAnswerAsync(visit.PatientId, cancellationToken);
            checks.Add(new Check(
                "answer saved: agreed, telehealth, by the client",
                current.GetStringOrNull("decision") == AiConsentEntry.ConsentedDecision
                    && current.GetStringOrNull("modality") == "telehealth"
                    && current.GetStringOrNull("consented_by") == "client",
                $"decision={current.GetStringOrNull("decision") ?? "nil"} "
                    + $"modality={current.GetStringOrNull("modality") ?? "nil"} "
                    + $"consented_by={current.GetStringOrNull("consented_by") ?? "nil"}"));
            var after = await consent.CheckAsync(visit.AppointmentId, cancellationToken: cancellationToken);
            checks.Add(new Check("after agreeing, the client reads as clear",
                after.Consent is RecordingConsent.Clear, $"{after.Consent}"));

            // Stop: the app ends the session (recording_complete), then queues and
            // uploads the audio.
            var ended = await client.RequestAsync(HttpMethod.Patch, $"/api/sessions/{sessionId}/status", token,
                new { status = AudioUploadClient.RecordingCompleteStatus }, cancellationToken);
            checks.Add(new Check("session recording_complete", ended.Status == 200, $"HTTP {ended.Status}"));

            // The note is what this flow exists to prove, so it always polls.
            checks.AddRange(await new QueuedUpload(baseUrl, client, token).RunAsync(
                sessionId, recording, pollForNote: true, pollSeconds, cancellationToken));
        }

        // -- Decline --------------------------------------------------------------

        private async Task DeclineAsync(
            List<Check> checks, Visits.Visit visit, string sessionId, RecordingConsentClient consent,
            CancellationToken cancellationToken)
        {
            // The client says no partway in. The app's decline stops the capture
            // first, so the recording is the first half of the visit.
            var half = seconds / 2;
            var recording = await FixtureRecorder.RecordAsync(
                micFixture, systemFixture, half, cancellationToken: cancellationToken, touch: Touch(cancellationToken));
            checks.AddRange(recording.Checks(half));

            // The app's decline: discard, return the session to a hand-written note,
            // save the answer.
            checks.AddRange(await DiscardDeclinedAsync(recording, sessionId));
            var handWritten = await client.RequestAsync(HttpMethod.Patch, $"/api/sessions/{sessionId}/status", token,
                new { status = "scheduled" }, cancellationToken);
            await consent.RecordAsync(
                new AiConsentAnswer(AiConsentEntry.DeclinedDecision, AiConsentModality.Telehealth, AiConsentGiver.Client),
                visit.PatientId, cancellationToken);

            var session = await client.RequestAsync(
                HttpMethod.Get, $"/api/sessions/{sessionId}", token, cancellationToken: cancellationToken);
            var status = session.Json.GetStringOrNull("status");
            checks.Add(new Check(
                "session back to a hand-written note, never transcribing",
                handWritten.Status == 200 && status == "scheduled",
                $"PATCH HTTP {handWritten.Status}, status now {status ?? "nil"}"));

            var current = await _visits.CurrentAnswerAsync(visit.PatientId, cancellationToken);
            checks.Add(new Check("decline saved",
                current.GetStringOrNull("decision") == AiConsentEntry.DeclinedDecision,
                $"decision={current.GetStringOrNull("decision") ?? "nil"}"));
            var declinedRead = await consent.CheckAsync(visit.AppointmentId, cancellationToken: cancellationToken);
            checks.Add(new Check("the client reads as declined",
                declinedRead.Consent is RecordingConsent.Declined, $"{declinedRead.Consent}"));

            var later = await _visits.SeedAsync(telehealth: true, patientId: visit.PatientId, cancellationToken);
            var laterStart = await _visits.StartAsync(later.AppointmentId, asking: true, cancellationToken);
            checks.Add(new Check(
                "a later recorded start is refused (CLIENT_DECLINED_AI_NOTES)",
                RecordingConsent.DeclinedOn(laterStart.Status, laterStart.Body) is not null,
                $"HTTP {laterStart.Status} {laterStart.BodyPrefix}"));
        }

        /// <summary>
        /// The app's decline discard (<c>RecordingCleaner.DiscardDeclined</c>) run
        /// against the worst case it has to undo: the stop already queued the
        /// upload. The queue entry goes first, then the session's capture
        /// directory, then any file left in it one by one. A drain afterwards
        /// must find nothing to send, and no audio may be left.
        /// </summary>
        private static async Task<IReadOnlyList<Check>> DiscardDeclinedAsync(
            FixtureRecorder.Outcome recording, string sessionId)
        {
            var queue = new UploadQueue(Path.Combine(
                Path.GetDirectoryName(recording.Directory) ?? Path.GetTempPath(), $"queue-{Guid.NewGuid():N}"));
            queue.Add(sessionId, recording.MicPath, recording.SystemPath, recording.MixedPath);
            var queuedAtStop = queue.Count;

            queue.Remove(sessionId);
            try { Directory.Delete(recording.Directory, recursive: true); }
            catch (Exception ex)
            {
                Harness.Log($"directory delete incomplete ({ex.Message}); deleting file by file");
                foreach (var file in Directory.EnumerateFiles(recording.Directory, "*", SearchOption.AllDirectories))
                {
                    try { File.Delete(file); }
                    catch (Exception fileEx) { Harness.Log($"could not delete {Path.GetFileName(file)}: {fileEx.Message}"); }
                }
            }

            var attempts = 0;
            await queue.DrainAsync(_ =>
            {
                attempts++;
                return Task.CompletedTask;
            });
            var left = FixtureRecorder.AudioFiles(recording.Directory);
            var queuedAfter = queue.Count;
            queue.DeleteStore();
            return
            [
                new Check(
                    "nothing queued or uploaded",
                    queuedAtStop == 1 && attempts == 0 && queuedAfter == 0,
                    $"queued at stop {queuedAtStop}, {attempts} upload attempt(s), {queuedAfter} queued after"),
                new Check(
                    "no audio left on disk",
                    left.Count == 0,
                    left.Count == 0 ? "capture directory has no audio" : $"left: {string.Join(", ", left)}"),
            ];
        }

        private Func<Task> Touch(CancellationToken cancellationToken) =>
            () => client.RequestAsync(HttpMethod.Post, "/api/auth/session/touch", token,
                cancellationToken: cancellationToken);
    }
}
