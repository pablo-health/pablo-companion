using System.Text.Json;
using PabloCompanion.Core;

namespace RecordHarness;

/// <summary>
/// The practice's ask-clients setting and audio retention window: read before a
/// consent run changes them, and put back afterwards.
/// </summary>
internal sealed class PracticeSetting(DeviceBoundClient client, string token)
{
    internal const string ConsentPath = "/api/users/me/practice/ai-notes-consent";
    internal const string RetentionPath = "/api/users/me/practice/audio-retention";

    /// <param name="Asked">Whether the practice asks clients about AI-assisted notes.</param>
    /// <param name="RetentionDays">The practice's audio retention window.</param>
    internal sealed record Snapshot(bool Asked, int RetentionDays);

    internal async Task<Snapshot> ReadAsync(CancellationToken cancellationToken)
    {
        var read = await client.RequestAsync(HttpMethod.Get, ConsentPath, token, cancellationToken: cancellationToken);
        var asked = read.Json.GetPropertyOrNull("ask_clients_about_ai_notes");
        var days = read.Json.GetPropertyOrNull("audio_retention_days");
        if (read.Status != 200
            || asked?.ValueKind is not (JsonValueKind.True or JsonValueKind.False)
            || days?.ValueKind != JsonValueKind.Number)
        {
            throw new HarnessException($"reading the practice's setting: HTTP {read.Status} {read.BodyPrefix}");
        }
        return new Snapshot(asked.Value.GetBoolean(), days.Value.GetInt32());
    }

    /// <summary>
    /// Puts the setting (and, when the run changed it, the retention window) back,
    /// then reads it back. Never throws, so a failure here never hides the gate's
    /// own failures; it comes back as a failed check instead.
    /// </summary>
    internal async Task<Check> RestoreAsync(Snapshot before, bool restoreRetention, CancellationToken cancellationToken)
    {
        const string name = "practice setting restored (read back)";
        try
        {
            var put = await client.RequestAsync(HttpMethod.Put, ConsentPath, token,
                new { ask_clients_about_ai_notes = before.Asked }, cancellationToken);
            var ok = put.Status is >= 200 and < 300;
            if (restoreRetention)
            {
                var retention = await client.RequestAsync(HttpMethod.Put, RetentionPath, token,
                    new { audio_retention_days = before.RetentionDays }, cancellationToken);
                ok &= retention.Status is >= 200 and < 300;
            }
            var now = await ReadAsync(cancellationToken);
            ok &= now == before;
            Harness.Log($"{(ok ? "Restored" : "FAILED to restore")} the practice's setting (asking: {before.Asked})");
            return new Check(name, ok,
                $"before asking={before.Asked} retention={before.RetentionDays}; "
                    + $"now asking={now.Asked} retention={now.RetentionDays}");
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            Harness.Log($"FAILED to restore the practice's setting: {ex.Message}");
            return new Check(name, false, ex.Message);
        }
    }
}

/// <summary>Seeds clients and appointments, and starts sessions from them the way the app does.</summary>
internal sealed class Visits(DeviceBoundClient client, string token, string firstName)
{
    /// <param name="PatientId">The client.</param>
    /// <param name="AppointmentId">The appointment the session starts from.</param>
    internal sealed record Visit(string PatientId, string AppointmentId);

    /// <summary>
    /// A client (new, unless <paramref name="patientId"/> is given) and a 50-minute
    /// appointment, telehealth when it carries a video link. The pinned test
    /// practice is shared with other runs and the server refuses an overlapping
    /// appointment, so a taken slot moves the visit on an hour, up to a day ahead.
    /// </summary>
    internal async Task<Visit> SeedAsync(bool telehealth, string? patientId, CancellationToken cancellationToken)
    {
        if (patientId is null)
        {
            var noise = Guid.NewGuid().ToString()[..8].ToLowerInvariant();
            var patient = await client.RequestAsync(HttpMethod.Post, "/api/patients", token, new
            {
                first_name = firstName,
                last_name = $"Harness-{noise}",
                status = "active",
            }, cancellationToken);
            patientId = patient.Json.GetStringOrNull("id")
                ?? throw new HarnessException($"patient create: HTTP {patient.Status} {patient.BodyPrefix}");
        }

        for (var hour = 0; hour < 24; hour++)
        {
            var start = DateTimeOffset.UtcNow.AddHours(hour).AddMinutes(5);
            var body = new Dictionary<string, object>
            {
                ["patient_id"] = patientId,
                ["title"] = $"{firstName} harness",
                ["start_at"] = DeviceBoundClient.Iso8601(start),
                ["end_at"] = DeviceBoundClient.Iso8601(start.AddMinutes(50)),
                ["duration_minutes"] = 50,
                ["session_type"] = "individual",
            };
            if (telehealth) body["video_link"] = "https://video.example/harness-room";

            var appointment = await client.RequestAsync(HttpMethod.Post, "/api/appointments", token, body, cancellationToken);
            if (appointment.Status == 409) continue;
            var appointmentId = appointment.Json.GetStringOrNull("id")
                ?? throw new HarnessException($"appointment create: HTTP {appointment.Status} {appointment.BodyPrefix}");
            return new Visit(patientId, appointmentId);
        }
        throw new HarnessException("no free appointment slot in the next 24 hours");
    }

    /// <summary>
    /// <c>POST /api/appointments/{id}/start-session</c> with exactly the body the
    /// app sends (<see cref="RecordingConsentClient.StartSessionBody"/>).
    /// </summary>
    internal Task<DeviceBoundClient.Response> StartAsync(
        string appointmentId, bool asking, CancellationToken cancellationToken) =>
        client.RequestRawAsync(HttpMethod.Post, $"/api/appointments/{appointmentId}/start-session", token,
            RecordingConsentClient.StartSessionBody(asking), cancellationToken);

    /// <summary>The client's current answer as the server holds it, or null.</summary>
    internal async Task<JsonElement?> CurrentAnswerAsync(string patientId, CancellationToken cancellationToken)
    {
        var stored = await client.RequestAsync(
            HttpMethod.Get, $"/api/patients/{patientId}/ai-consent", token, cancellationToken: cancellationToken);
        return stored.Json.GetPropertyOrNull("current");
    }
}
