using System.Text.Json;

namespace RecordHarness;

/// <summary>
/// Decides whether a generated SOAP note actually reflects the recorded audio.
///
/// This is the gate's sharpest edge and the easiest thing to get wrong in a way
/// that reads as success: the SOAP LLM emits well-formed placeholder sentences
/// ("No transcript provided.") when transcription comes back empty, so a note can
/// be structurally perfect — four sections, real prose — and still be evidence
/// that the audio never transcribed. An earlier prod run passed on exactly that.
///
/// Mirrors <c>sentenceHasText</c> / <c>sectionHasContent</c> in the backend e2e
/// spec and the macOS harness; the three must agree.
/// </summary>
internal static class SoapGate
{
    internal static readonly string[] Sections = ["subjective", "objective", "assessment", "plan"];

    /// <param name="Present">How many of the four sections exist on the note.</param>
    /// <param name="Populated">How many carry at least one transcript-anchored sentence.</param>
    internal readonly record struct Result(int Present, int Populated)
    {
        internal bool Ok => Present == Sections.Length && Populated > 0;

        internal string Detail => $"{Present}/4 sections present, {Populated} populated";
    }

    /// <summary>Counts sections present and genuinely populated on a note's content.</summary>
    internal static Result Evaluate(JsonElement? content) => new(
        Present: Sections.Count(s => content.GetPropertyOrNull(s) is not null),
        Populated: Sections.Count(s => SectionHasContent(content.GetPropertyOrNull(s))));

    /// <summary>
    /// Whether a section holds any real content. Section values are <c>{text: …}</c>
    /// sentence objects, or arrays of them — not bare strings.
    /// </summary>
    internal static bool SectionHasContent(JsonElement? section)
    {
        if (section is null || section.Value.ValueKind != JsonValueKind.Object) return false;

        foreach (var property in section.Value.EnumerateObject())
        {
            if (property.Value.ValueKind == JsonValueKind.Array)
            {
                if (property.Value.EnumerateArray().Any(SentenceHasText)) return true;
            }
            else if (SentenceHasText(property.Value))
            {
                return true;
            }
        }
        return false;
    }

    /// <summary>
    /// Whether a sentence counts as <i>audio-derived</i> content: it must carry
    /// non-empty <c>text</c> AND be anchored to the transcript, by non-empty
    /// <c>source_segment_ids</c> or a <c>confidence_score</c> above zero.
    ///
    /// The anchor requirement is the whole point. Placeholder sentences have real
    /// text but no source segments and zero confidence, so a text-only check
    /// passes them and the gate reports success on a silent recording.
    /// </summary>
    internal static bool SentenceHasText(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object) return false;

        var text = value.GetPropertyOrNull("text");
        if (text?.ValueKind != JsonValueKind.String) return false;
        if (string.IsNullOrWhiteSpace(text.Value.GetString())) return false;

        var sources = value.GetPropertyOrNull("source_segment_ids");
        var hasSource = sources?.ValueKind == JsonValueKind.Array && sources.Value.GetArrayLength() > 0;

        var confidence = value.GetPropertyOrNull("confidence_score");
        var score = confidence?.ValueKind == JsonValueKind.Number ? confidence.Value.GetDouble() : 0;

        return hasSource || score > 0;
    }

    // --- Polling the session to its note ---

    /// <summary>
    /// Polls the session until it reaches <c>pending_review</c> (then gates the
    /// embedded note), <c>failed</c>, or the deadline.
    /// </summary>
    internal static async Task<Check> PollAsync(
        DeviceBoundClient client,
        string token,
        string sessionId,
        double pollSeconds,
        CancellationToken cancellationToken)
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
                return EvaluateNote(note);
            }

            await Task.Delay(TimeSpan.FromSeconds(5), cancellationToken);
        }

        return new Check("SOAP generated", false, $"deadline hit (last status '{lastStatus}')");
    }

    /// <summary>
    /// The embedded note must be a 4-section SOAP with at least one section
    /// carrying transcript-anchored content.
    /// </summary>
    internal static Check EvaluateNote(JsonElement? note)
    {
        if (note is null || note.Value.ValueKind != JsonValueKind.Object)
            return new Check("SOAP generated", false, "no note on session");

        var noteType = note.GetStringOrNull("note_type");
        if (noteType != "soap")
            return new Check("SOAP generated", false, $"note_type {noteType ?? "nil"}");

        var result = Evaluate(note.GetPropertyOrNull("content"));
        return new Check("4-section SOAP with content", result.Ok, result.Detail);
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
        Harness.Log($"----- generated SOAP (note_type={noteType}) -----\n{text}\n-----");
    }
}
