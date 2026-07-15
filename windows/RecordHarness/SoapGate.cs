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
}
