using System.Text.Json;
using RecordHarness;

namespace PabloCompanion.Tests.Harness;

/// <summary>
/// Pins the SOAP gate. The failure this guards against is the dangerous kind: a
/// note that looks complete and reads fine, but was generated from an empty
/// transcript. A gate that only checks for text passes it, and reports a healthy
/// recording pipeline that in fact captured nothing usable.
/// </summary>
public class SoapGateTests
{
    private static JsonElement Json(string raw)
    {
        using var doc = JsonDocument.Parse(raw);
        return doc.RootElement.Clone();
    }

    /// A sentence anchored to the transcript: what real, audio-derived content looks like.
    private const string AnchoredSentence =
        """{"text":"Client reports poor sleep.","source_segment_ids":["seg-1"],"confidence_score":0.94}""";

    /// The placeholder the SOAP LLM emits when transcription returned nothing.
    private const string PlaceholderSentence =
        """{"text":"No transcript provided.","source_segment_ids":[],"confidence_score":0}""";

    [Fact]
    public void AnchoredSentence_CountsAsContent()
    {
        Assert.True(SoapGate.SentenceHasText(Json(AnchoredSentence)));
    }

    [Fact]
    public void PlaceholderSentence_DoesNotCountAsContent()
    {
        // The regression that motivated the anchor requirement: real text, zero
        // confidence, no source segments.
        Assert.False(SoapGate.SentenceHasText(Json(PlaceholderSentence)));
    }

    [Fact]
    public void ConfidenceAloneAnchorsASentence()
    {
        // Either anchor suffices — some notes carry confidence without segment ids.
        Assert.True(SoapGate.SentenceHasText(
            Json("""{"text":"Client is anxious.","confidence_score":0.5}""")));
    }

    [Fact]
    public void SourceSegmentsAloneAnchorASentence()
    {
        Assert.True(SoapGate.SentenceHasText(
            Json("""{"text":"Client is anxious.","source_segment_ids":["seg-9"]}""")));
    }

    [Theory]
    [InlineData("""{"source_segment_ids":["seg-1"],"confidence_score":0.9}""")] // anchored but no text
    [InlineData("""{"text":"","source_segment_ids":["seg-1"]}""")]              // empty text
    [InlineData("""{"text":"   ","confidence_score":0.9}""")]                   // whitespace only
    [InlineData("\"a bare string\"")]                                           // not a sentence object
    [InlineData("""{"text":"Anchored?","source_segment_ids":[],"confidence_score":0}""")]
    public void NonContentShapes_AreRejected(string raw)
    {
        Assert.False(SoapGate.SentenceHasText(Json(raw)));
    }

    [Fact]
    public void SectionWithAnArrayOfSentences_HasContent()
    {
        // The common shape: a section's fields hold arrays of sentence objects.
        Assert.True(SoapGate.SectionHasContent(
            Json($$"""{"summary":[{{PlaceholderSentence}}, {{AnchoredSentence}}]}""")));
    }

    [Fact]
    public void SectionOfOnlyPlaceholders_HasNoContent()
    {
        Assert.False(SoapGate.SectionHasContent(
            Json($$"""{"summary":[{{PlaceholderSentence}}],"detail":{{PlaceholderSentence}}}""")));
    }

    [Fact]
    public void SectionWithASingleSentenceObject_HasContent()
    {
        Assert.True(SoapGate.SectionHasContent(Json($$"""{"summary":{{AnchoredSentence}}}""")));
    }

    [Fact]
    public void EmptyOrMissingSection_HasNoContent()
    {
        Assert.False(SoapGate.SectionHasContent(Json("{}")));
        Assert.False(SoapGate.SectionHasContent(null));
    }

    [Fact]
    public void FullyAnchoredNote_PassesTheGate()
    {
        var content = Json($$"""
        {
          "subjective": {"summary": [{{AnchoredSentence}}]},
          "objective":  {"summary": [{{AnchoredSentence}}]},
          "assessment": {"summary": [{{AnchoredSentence}}]},
          "plan":       {"summary": [{{AnchoredSentence}}]}
        }
        """);

        var result = SoapGate.Evaluate(content);

        Assert.True(result.Ok);
        Assert.Equal(4, result.Present);
        Assert.Equal(4, result.Populated);
    }

    [Fact]
    public void NoteOfOnlyPlaceholders_FailsTheGateDespiteBeingWellFormed()
    {
        // This is the exact shape a prod run passed on before the anchor check:
        // four sections, real prose, no transcript behind any of it.
        var content = Json($$"""
        {
          "subjective": {"summary": [{{PlaceholderSentence}}]},
          "objective":  {"summary": [{{PlaceholderSentence}}]},
          "assessment": {"summary": [{{PlaceholderSentence}}]},
          "plan":       {"summary": [{{PlaceholderSentence}}]}
        }
        """);

        var result = SoapGate.Evaluate(content);

        Assert.False(result.Ok);
        Assert.Equal(4, result.Present);   // structurally complete...
        Assert.Equal(0, result.Populated); // ...and entirely unanchored
        Assert.Equal("4/4 sections present, 0 populated", result.Detail);
    }

    [Fact]
    public void PartiallyPopulatedNote_PassesWhenAllSectionsArePresent()
    {
        // Matches the macOS gate: every section present, at least one anchored.
        var content = Json($$"""
        {
          "subjective": {"summary": [{{AnchoredSentence}}]},
          "objective":  {"summary": [{{PlaceholderSentence}}]},
          "assessment": {"summary": [{{PlaceholderSentence}}]},
          "plan":       {"summary": [{{PlaceholderSentence}}]}
        }
        """);

        var result = SoapGate.Evaluate(content);

        Assert.True(result.Ok);
        Assert.Equal(1, result.Populated);
    }

    [Fact]
    public void NoteMissingASection_FailsTheGate()
    {
        var content = Json($$"""
        {
          "subjective": {"summary": [{{AnchoredSentence}}]},
          "objective":  {"summary": [{{AnchoredSentence}}]},
          "assessment": {"summary": [{{AnchoredSentence}}]}
        }
        """);

        var result = SoapGate.Evaluate(content);

        Assert.False(result.Ok);
        Assert.Equal(3, result.Present);
    }
}
