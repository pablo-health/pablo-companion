using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PabloCompanion.Core;

/// <summary>
/// What a client's answer about AI-assisted notes means for starting a
/// recording: go ahead, ask once recording starts, or stop.
///
/// Mirrors the web app's check. Only a practice that asks its clients (the
/// practice's AI-notes consent setting) is ever anything but <see cref="Clear"/>.
/// The server refuses a declined client's recording regardless; this is what
/// lets the companion say so before the microphone arms.
///
/// When nobody has asked the client yet, in the room or over telehealth, the
/// companion offers one way to record: ask once recording starts, so the
/// answer is on the recording (<see cref="AskOnRecording"/>). The read-aloud
/// script opens "I've started recording our session", so it is only shown once
/// that is true. There is no "record anyway" and no pre-selected "agreed": a
/// yes is recorded only as the answer given on the recording, and a no stops
/// and deletes it. The server refuses a telehealth start with nothing on file
/// unless the start says it is asking (<c>asking_consent_on_recording</c>).
///
/// The C# mirror of macOS <c>CompanionSessionCore.RecordingConsent</c>.
/// </summary>
public abstract record RecordingConsent
{
    private RecordingConsent() { }

    /// <summary>Record. The practice does not ask, or the client agreed.</summary>
    public sealed record Clear : RecordingConsent;

    /// <summary>
    /// The practice asks and nobody has asked this client yet: offer asking once
    /// recording starts ("Start recording and ask"), or not recording.
    /// </summary>
    public sealed record AskOnRecording(AiConsentModality Modality) : RecordingConsent;

    /// <summary>
    /// The clinician chose to ask once recording starts: start, telling the
    /// server so, and show the script once recording is running.
    /// </summary>
    public sealed record AskingOnRecording(AiConsentModality Modality) : RecordingConsent;

    /// <summary>The client declined. <paramref name="On"/> is the day they answered, as <c>YYYY-MM-DD</c>.</summary>
    public sealed record Declined(string On) : RecordingConsent;

    /// <summary>The single <see cref="Clear"/> value.</summary>
    public static readonly RecordingConsent ClearValue = new Clear();

    /// <summary>The backend <c>error.code</c> on a start refused because the client declined.</summary>
    public const string DeclinedErrorCode = "CLIENT_DECLINED_AI_NOTES";

    /// <summary>
    /// The backend <c>error.code</c> on a telehealth start refused because nobody
    /// has asked the client and the start did not say it is asking.
    /// </summary>
    public const string ConsentNeededErrorCode = "CLIENT_AI_CONSENT_NEEDED";

    /// <summary>
    /// Combines the practice setting with the client's current answer and where
    /// the session is.
    /// </summary>
    public static RecordingConsent Evaluate(bool asksClients, AiConsentEntry? current, bool telehealth = false)
    {
        if (!asksClients) return ClearValue;
        if (current is null)
            return new AskOnRecording(telehealth ? AiConsentModality.Telehealth : AiConsentModality.InPerson);
        return current.Decision == AiConsentEntry.DeclinedDecision ? new Declined(current.EffectiveOn) : ClearValue;
    }

    /// <summary>Whether the session start tells the server the clinician is asking once recording starts.</summary>
    public bool StartsAskingOnRecording => AskingModality is not null;

    /// <summary>Where the session is, when the clinician is asking once recording starts; null otherwise.</summary>
    public AiConsentModality? AskingModality => this is AskingOnRecording asking ? asking.Modality : null;

    /// <summary>
    /// The answer for a start handed off from the web app.
    ///
    /// <paramref name="webAskingOnRecording"/>: for a start with nothing on file,
    /// the web app already offered "Ask now" and the clinician took it, so the
    /// companion starts asking on the recording without offering it again.
    ///
    /// <paramref name="webAlreadyAsked"/>: for an in-person visit, the web app
    /// already asked "No consent on file" and the clinician chose to record anyway
    /// there, so a missing in-person answer reads as clear rather than asking the
    /// same question twice. It never clears a telehealth start: the server would
    /// refuse it.
    ///
    /// A decline still stops either way: it may have been recorded after the web
    /// app asked.
    /// </summary>
    public RecordingConsent HandedOff(bool webAlreadyAsked, bool webAskingOnRecording = false) => this switch
    {
        AskOnRecording ask when webAskingOnRecording => new AskingOnRecording(ask.Modality),
        AskOnRecording { Modality: AiConsentModality.InPerson } when webAlreadyAsked => ClearValue,
        _ => this,
    };

    /// <summary>
    /// Whether a refused session start is the server's
    /// <c>403 CLIENT_AI_CONSENT_NEEDED</c>: a telehealth client nobody has asked.
    /// </summary>
    public static bool IsConsentNeeded(int statusCode, string body)
        => statusCode == 403 && ReadError(body) is { Code: ConsentNeededErrorCode };

    /// <summary>
    /// Reads a refused session start. Returns the day the client declined when the
    /// response is the server's <c>403 CLIENT_DECLINED_AI_NOTES</c>, an empty
    /// string when the refusal carries no date, and null for anything else.
    ///
    /// Body shape: <c>{"error": {"code", "message", "details": {"declined_on"}}}</c>.
    /// </summary>
    public static string? DeclinedOn(int statusCode, string body)
    {
        if (statusCode != 403) return null;
        var error = ReadError(body);
        if (error is not { Code: DeclinedErrorCode }) return null;
        return error.Value.Details.TryGetValue("declined_on", out var on) ? on : "";
    }

    /// <summary>
    /// Parses the standard error envelope's code and its string-valued
    /// <c>details</c>. Null for a body that is not the envelope.
    /// </summary>
    public static (string? Code, IReadOnlyDictionary<string, string> Details)? ReadError(string? body)
    {
        if (string.IsNullOrWhiteSpace(body)) return null;
        try
        {
            using var doc = JsonDocument.Parse(body);
            if (doc.RootElement.ValueKind != JsonValueKind.Object ||
                !doc.RootElement.TryGetProperty("error", out var error) ||
                error.ValueKind != JsonValueKind.Object) return null;

            var code = error.TryGetProperty("code", out var c) && c.ValueKind == JsonValueKind.String
                ? c.GetString() : null;
            var details = new Dictionary<string, string>(StringComparer.Ordinal);
            if (error.TryGetProperty("details", out var d) && d.ValueKind == JsonValueKind.Object)
            {
                foreach (var property in d.EnumerateObject())
                {
                    if (property.Value.ValueKind == JsonValueKind.String)
                        details[property.Name] = property.Value.GetString() ?? "";
                }
            }
            return (code, details);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>
    /// A <c>YYYY-MM-DD</c> day as a person reads it ("Oct 5, 2026" in en-US).
    /// Returns the input unchanged if it is not a calendar day.
    /// </summary>
    public static string DisplayDate(string isoDay, CultureInfo? culture = null)
    {
        if (!DateOnly.TryParseExact(isoDay, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var day))
            return isoDay;
        return day.ToString("MMM d, yyyy", culture ?? CultureInfo.CurrentCulture);
    }
}

/// <summary>
/// One answer on a client's AI-notes consent record
/// (<c>GET /api/patients/{id}/ai-consent</c> -> <c>current</c>).
/// </summary>
public sealed record AiConsentEntry(
    [property: JsonPropertyName("decision")] string Decision,
    [property: JsonPropertyName("effective_on")] string EffectiveOn)
{
    public const string ConsentedDecision = "consented";
    public const string DeclinedDecision = "declined";
}

/// <summary>
/// Whether a visit is telehealth: a video service, a video link, or a telehealth
/// place of service ("02", "10"). Mirrors <c>is_telehealth</c> on the server,
/// which is what decides.
/// </summary>
public static class Telehealth
{
    /// <summary>Place-of-service codes for a visit held by video or phone.</summary>
    public static readonly IReadOnlySet<string> Places = new HashSet<string>(StringComparer.Ordinal) { "02", "10" };

    public static bool IsTelehealth(string? provider, string? videoLink, string? placeOfService)
    {
        if (!string.IsNullOrEmpty(provider)) return true;
        if (!string.IsNullOrEmpty(videoLink)) return true;
        return placeOfService is not null && Places.Contains(placeOfService);
    }

    /// <summary>The same answer as a modality.</summary>
    public static AiConsentModality Modality(string? provider, string? videoLink, string? placeOfService)
        => IsTelehealth(provider, videoLink, placeOfService) ? AiConsentModality.Telehealth : AiConsentModality.InPerson;
}

/// <summary>Where a client's answer was given (<c>modality</c> on the consent record).</summary>
public enum AiConsentModality
{
    InPerson,
    Telehealth,
}

/// <summary>
/// Who gave the answer: the client, or a parent or guardian for them
/// (<c>consented_by</c> on the consent record).
/// </summary>
public enum AiConsentGiver
{
    Client,
    Parent,
    Guardian,
}

public static class AiConsentWire
{
    public static string Wire(this AiConsentModality modality) => modality switch
    {
        AiConsentModality.Telehealth => "telehealth",
        _ => "in_person",
    };

    public static string Wire(this AiConsentGiver giver) => giver switch
    {
        AiConsentGiver.Parent => "parent",
        AiConsentGiver.Guardian => "guardian",
        _ => "client",
    };

    /// <summary>
    /// As a person reads it. The companion has no practice word for the people it
    /// serves, so it says "Client".
    /// </summary>
    public static string Word(this AiConsentGiver giver) => giver switch
    {
        AiConsentGiver.Parent => "Parent",
        AiConsentGiver.Guardian => "Guardian",
        _ => "Client",
    };
}

/// <summary>
/// One answer as the clinician records it (<c>POST /api/patients/{id}/ai-consent</c>).
/// No date is sent: the server dates it on the clinician's own calendar day, so
/// an evening entry is not dated tomorrow.
/// </summary>
public sealed record AiConsentAnswer(
    string Decision,
    AiConsentModality Modality,
    AiConsentGiver ConsentedBy,
    string? ClientStatedLocation = null)
{
    /// <summary>The longest place the server keeps; a place, not a note.</summary>
    public const int LocationMaxLength = 200;

    /// <summary>
    /// The request body. A place is sent only for telehealth, trimmed, and only
    /// when one was given.
    /// </summary>
    public IReadOnlyDictionary<string, string> Body
    {
        get
        {
            var body = new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["decision"] = Decision,
                ["modality"] = Modality.Wire(),
                ["consented_by"] = ConsentedBy.Wire(),
            };
            var place = (ClientStatedLocation ?? "").Trim();
            if (Modality == AiConsentModality.Telehealth && place.Length > 0)
                body["client_stated_location"] = place.Length > LocationMaxLength ? place[..LocationMaxLength] : place;
            return body;
        }
    }
}

/// <summary>Everything the confirmation needs to decide what to show before arming.</summary>
/// <param name="Consent">The client's answer, as it bears on recording.</param>
/// <param name="AsksClients">Whether the practice asks its clients.</param>
/// <param name="AudioRetentionDays">How long the practice keeps session audio, read aloud in the script.</param>
/// <param name="PatientId">The client the answer belongs to. Null when the practice does not ask
/// (the client is never looked up then).</param>
public sealed record RecordingConsentCheck(
    RecordingConsent Consent,
    bool AsksClients,
    int AudioRetentionDays,
    string? PatientId);

/// <summary>
/// What the clinician reads aloud once recording has started, so the client's
/// answer is on the recording itself. Mirrors the web app's script word for word
/// so a client hears the same thing whichever app the clinician starts from.
///
/// A window of 0 days means the audio is deleted once the note is signed.
/// Signing enforces that, so the script says it plainly. For a number of days it
/// states the practice's window and no more.
/// </summary>
public static class ConsentScript
{
    /// <summary><c>audio_retention_days</c> for "deleted once the note is signed".</summary>
    public const int DeletedOnSigning = 0;

    public static IReadOnlyList<string> Lines(int retentionDays) =>
    [
        "I've started recording our session.",
        "The recording is turned into a written transcript, and an AI tool uses it to draft my notes. "
            + "I read and correct every note myself.",
        retentionDays == DeletedOnSigning
            ? "The audio is deleted once your note is signed."
            : $"The audio is kept for up to {Retention(retentionDays)}.",
        "You can say no, now or at any time.",
        "Is that all right with you?",
    ];

    /// <summary>A retention window as someone would say it: "1 year", "2 years", "90 days".</summary>
    public static string Retention(int days)
    {
        if (days > 0 && days % 365 == 0)
        {
            var years = days / 365;
            return years == 1 ? "1 year" : $"{years} years";
        }
        return days == 1 ? "1 day" : $"{days} days";
    }
}
