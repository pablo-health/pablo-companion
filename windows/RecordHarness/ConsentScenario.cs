using PabloCompanion.Core;

namespace RecordHarness;

/// <summary>
/// <c>PRACTICE_SCENARIO=consent</c>: drives the companion's AI-notes consent wire
/// path (<see cref="RecordingConsentClient"/>, the session-start body and the
/// consent answer body) against a backend, as a signed-in, device-enrolled
/// clinician:
///
///   turn on asking clients (and, with <c>CONSENT_RETENTION_DAYS</c>, set the
///   audio retention window) → seed a client with a telehealth visit and one with
///   an in-person visit →
///   - the telehealth visit reads as "ask on the recording", and the script names
///     the practice's window;
///   - a plain start is refused with <c>403 CLIENT_AI_CONSENT_NEEDED</c>;
///   - a start that says it is asking on the recording is accepted;
///   - the client's answer is saved as given over telehealth, with who answered
///     and where they said they were, and then reads as clear;
///   - a decline on the recording is saved, the session returns to a hand-written
///     note, and a later recorded start is refused;
///   - the in-person visit reads as "ask on the recording" too, and its answer is
///     saved as given in person.
///
/// No audio is captured here; the <c>visit</c> scenario runs the same gate with a
/// real recording, upload and note (or, on a decline, no audio left).
///
/// The practice's setting and retention window are put back as they were when
/// the run ends, pass or fail, and read back to prove it, so a run against a
/// shared test practice leaves no trace on the other tests that use it.
///
/// The Windows mirror of the macOS <c>ConsentScenario</c>.
///
/// Environment:
///   PRACTICE_BASE_URL       backend base URL
///   FB_API_KEY + FB_* creds sign-in plumbing, as for <c>record</c>
///   CONSENT_RETENTION_DAYS  optional; e.g. 0 for "deleted once signed"
///   REFRESH_OUT             path to write the rotated refresh token to
/// </summary>
public static class ConsentScenario
{
    public static async Task RunAsync(CancellationToken cancellationToken = default)
    {
        var baseUrl = Harness.Env("PRACTICE_BASE_URL") ?? "https://app.pablo.health";
        int? retention = int.TryParse(Harness.Env("CONSENT_RETENTION_DAYS"), out var days) ? days : null;
        var auth = await Harness.SignInAsync(cancellationToken);

        using var client = new DeviceBoundClient(baseUrl, Guid.NewGuid().ToString().ToLowerInvariant());
        var enrollment = await client.EnrollAsync(auth.IdToken, auth.RefreshToken, cancellationToken: cancellationToken);
        var token = enrollment.IdToken;

        var practice = new PracticeSetting(client, token);
        var before = await practice.ReadAsync(cancellationToken);
        var checks = new List<Check>
        {
            new("enrollment accepted at /native/exchange", enrollment.ExchangeStatus == 200,
                $"status {enrollment.ExchangeStatus}"),
        };
        try
        {
            await new Driver(baseUrl, client, token, retention).RunAsync(checks, cancellationToken);
        }
        finally
        {
            checks.Add(await practice.RestoreAsync(before, restoreRetention: retention is not null, cancellationToken));
        }
        GateSummary.Report(checks, "consent gate summary", "CONSENT GATE PASSED");
    }

    private sealed class Driver(string baseUrl, DeviceBoundClient client, string token, int? retentionDays)
    {
        public async Task RunAsync(List<Check> checks, CancellationToken cancellationToken)
        {
            var turnOn = await client.RequestAsync(HttpMethod.Put, PracticeSetting.ConsentPath, token,
                new { ask_clients_about_ai_notes = true }, cancellationToken);
            checks.Add(new Check("practice asks clients", turnOn.Status is >= 200 and < 300, $"PUT HTTP {turnOn.Status}"));
            if (retentionDays is { } days)
            {
                var put = await client.RequestAsync(HttpMethod.Put, PracticeSetting.RetentionPath, token,
                    new { audio_retention_days = days }, cancellationToken);
                checks.Add(new Check("retention window set", put.Status is >= 200 and < 300, $"{days} days, HTTP {put.Status}"));
            }

            var consent = new RecordingConsentClient(
                () => baseUrl, () => Task.FromResult(token), client.AttachBinding,
                new Dictionary<string, string> { ["X-Client-Type"] = "pablo-companion-windows/1.0" });
            var visits = new Visits(client, token, "Consent");

            // -- Telehealth, nothing on file ------------------------------------
            var remote = await visits.SeedAsync(telehealth: true, patientId: null, cancellationToken);
            var read = await consent.CheckAsync(remote.AppointmentId, cancellationToken: cancellationToken);
            checks.Add(new Check(
                "telehealth visit offers only asking on the recording",
                read.Consent == new RecordingConsent.AskOnRecording(AiConsentModality.Telehealth),
                $"{read.Consent}"));
            var script = ConsentScript.Lines(read.AudioRetentionDays);
            var wording = read.AudioRetentionDays == ConsentScript.DeletedOnSigning
                ? "deleted once your note is signed"
                : ConsentScript.Retention(read.AudioRetentionDays);
            checks.Add(new Check(
                "script names the practice's window",
                script[2].Contains(wording, StringComparison.Ordinal)
                    && (retentionDays is null || read.AudioRetentionDays == retentionDays),
                $"retention {read.AudioRetentionDays}: {script[2]}"));

            var plain = await visits.StartAsync(remote.AppointmentId, asking: false, cancellationToken);
            checks.Add(new Check(
                "plain telehealth start is refused (CLIENT_AI_CONSENT_NEEDED)",
                RecordingConsent.IsConsentNeeded(plain.Status, plain.Body),
                $"HTTP {plain.Status} {plain.BodyPrefix}"));

            var asking = await visits.StartAsync(remote.AppointmentId, asking: true, cancellationToken);
            checks.Add(new Check(
                "'Ask now' start (asking_consent_on_recording) is accepted",
                asking.Status is >= 200 and < 300,
                $"HTTP {asking.Status}, body {RecordingConsentClient.StartSessionBody(true)}"));

            await consent.RecordAsync(
                new AiConsentAnswer(AiConsentEntry.ConsentedDecision, AiConsentModality.Telehealth,
                    AiConsentGiver.Parent, " At home "),
                remote.PatientId, cancellationToken);
            var stored = await visits.CurrentAnswerAsync(remote.PatientId, cancellationToken);
            checks.Add(new Check(
                "answer saved as given over telehealth",
                stored.GetStringOrNull("modality") == "telehealth"
                    && stored.GetStringOrNull("consented_by") == "parent"
                    && stored.GetStringOrNull("client_stated_location") == "At home",
                $"modality={stored.GetStringOrNull("modality") ?? "nil"} "
                    + $"consented_by={stored.GetStringOrNull("consented_by") ?? "nil"} "
                    + $"location={stored.GetStringOrNull("client_stated_location") ?? "nil"}"));
            var after = await consent.CheckAsync(remote.AppointmentId, cancellationToken: cancellationToken);
            checks.Add(new Check("after agreeing, the client reads as clear",
                after.Consent is RecordingConsent.Clear, $"{after.Consent}"));

            // -- Telehealth, declined on the recording --------------------------
            // The app stops and deletes the recording, saves the decline, and
            // returns the session to a hand-written note (scheduled, the state the
            // web starts one in with `recording: false`).
            var declining = await visits.SeedAsync(telehealth: true, patientId: null, cancellationToken);
            var declinedStart = await visits.StartAsync(declining.AppointmentId, asking: true, cancellationToken);
            var declinedSession = declinedStart.Json.GetStringOrNull("id") ?? "";
            var running = await client.RequestAsync(HttpMethod.Patch, $"/api/sessions/{declinedSession}/status",
                token, new { status = "in_progress" }, cancellationToken);
            await consent.RecordAsync(
                new AiConsentAnswer(AiConsentEntry.DeclinedDecision, AiConsentModality.Telehealth, AiConsentGiver.Client),
                declining.PatientId, cancellationToken);
            var handWritten = await client.RequestAsync(HttpMethod.Patch, $"/api/sessions/{declinedSession}/status",
                token, new { status = "scheduled" }, cancellationToken);
            checks.Add(new Check(
                "a decline returns the session to a hand-written note",
                running.Status == 200 && handWritten.Status == 200
                    && handWritten.Json.GetStringOrNull("status") == "scheduled",
                $"in_progress HTTP {running.Status}, then scheduled HTTP {handWritten.Status} "
                    + $"status={handWritten.Json.GetStringOrNull("status") ?? "nil"}"));
            var declinedAnswer = await visits.CurrentAnswerAsync(declining.PatientId, cancellationToken);
            checks.Add(new Check("decline saved",
                declinedAnswer.GetStringOrNull("decision") == AiConsentEntry.DeclinedDecision,
                $"decision={declinedAnswer.GetStringOrNull("decision") ?? "nil"}"));
            var later = await visits.SeedAsync(telehealth: true, patientId: declining.PatientId, cancellationToken);
            var laterStart = await visits.StartAsync(later.AppointmentId, asking: true, cancellationToken);
            checks.Add(new Check(
                "after a decline, a later recorded start is refused (CLIENT_DECLINED_AI_NOTES)",
                RecordingConsent.DeclinedOn(laterStart.Status, laterStart.Body) is not null,
                $"HTTP {laterStart.Status} {laterStart.BodyPrefix}"));

            // -- In person, nothing on file -------------------------------------
            var office = await visits.SeedAsync(telehealth: false, patientId: null, cancellationToken);
            var inPerson = await consent.CheckAsync(office.AppointmentId, cancellationToken: cancellationToken);
            checks.Add(new Check(
                "in-person visit offers asking on the recording",
                inPerson.Consent == new RecordingConsent.AskOnRecording(AiConsentModality.InPerson),
                $"{inPerson.Consent}"));
            var officeStart = await visits.StartAsync(office.AppointmentId, asking: true, cancellationToken);
            checks.Add(new Check("in-person start asking on the recording is accepted",
                officeStart.Status is >= 200 and < 300, $"HTTP {officeStart.Status}"));
            await consent.RecordAsync(
                new AiConsentAnswer(AiConsentEntry.ConsentedDecision, AiConsentModality.InPerson, AiConsentGiver.Client),
                office.PatientId, cancellationToken);
            var officeStored = await visits.CurrentAnswerAsync(office.PatientId, cancellationToken);
            checks.Add(new Check(
                "answer saved as given in person",
                officeStored.GetStringOrNull("modality") == "in_person"
                    && officeStored.GetStringOrNull("client_stated_location") is null,
                $"modality={officeStored.GetStringOrNull("modality") ?? "nil"}"));
        }
    }
}
